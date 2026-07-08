# RayMol Code Review — Bugs, Memory Leaks & Concurrency

**Date:** 2026-06-27
**Scope:** RayMol fork-specific code only (the delta vs. `upstream/master` = schrodinger/pymol-open-source). ~36K LOC: Metal + GL renderers, AppKit/iOS entry points, modified PyMOL representations, the SwiftUI app, the MCP server, Python AppKit panels, Metal shaders, and packaging scripts.
**Method:** 27 subsystem×lens review passes; **every** candidate finding was then adversarially re-checked against the real code by an independent verifier (default = "refute"). Of 96 candidates, **65 confirmed** and **31 rejected** as false positives (listed at the end so they aren't re-reported later).
**Nothing in the codebase was modified — this is a report only.**

Severity of confirmed findings: **7 high · 19 medium · 33 low · 6 info**. There are no confirmed crash-on-startup / corruption-class "critical" defects — the two biggest Metal leaks were filed as critical by the first pass and correctly down-graded to high (gradual unbounded growth, not instant failure).

---

## Critical context that shapes everything below

The core C++/Objective-C++ files (`layer0..layer5`, `layerGraphics`) are compiled by CMake/`setup.py` **without `-fobjc-arc`** → **Manual Reference Counting (MRC)**. Confirmed: `appkit/CMakeLists.txt` `PYMOL_COMPILE_FLAGS` carries no ARC flag, and `RendererMetal.mm` already uses explicit `[x retain]/[x release]`. The SwiftUI Xcode project's `CLANG_ENABLE_OBJC_ARC=YES` does **not** apply to these files (they're built by the cmake `pymol_core` target, not the Xcode target).

Consequence: in `.mm` core files, every `alloc`/`new…`/`copy` (+1) must be balanced by `release`/`autorelease`, and **there is no `@autoreleasepool` anywhere in `RendererMetal.mm`**, so even "autoreleased" reasoning doesn't save per-frame allocations. This single fact drives the entire leak cluster (Theme 1).

By contrast the SwiftUI app is ARC — its risks are retain cycles and force-unwrap crashes, not missing releases.

---

## Theme 1 — Per-frame Metal memory/resource leaks (MRC), `RendererMetal.mm` — **highest impact**

These leak on the **live render path**, i.e. continuously while the app is just displaying a molecule. Memory grows unbounded for the life of the session → ballooning RAM and eventual OOM-jettison, worst on iPad. This is the most important cluster to fix.

| # | Sev | What leaks (per…) | Location |
|---|-----|-------------------|----------|
| H-2 | high | `MTLRenderPassDescriptor` ×up-to-8 **per presented frame** (`[[…alloc] init]`, never released; no pool) | `layerGraphics/metal/RendererMetal.mm:1759-2002` (`runPostChain`) |
| H-3 | high | `MTLDepthStencilState` **+ descriptor per transparent draw call** (created inline, passed to `setDepthStencilState:`, +1 dropped) | `RendererMetal.mm:3863` (+ `:4092, :4514, :4970, :2105, :5197`) |
| H-4 | high | every cached `MTLBuffer` in `_vboCache`/`_buffers` (STL `clear()` does **not** release under MRC; keyed by CPU ptr that churns on geometry rebuild) | `RendererMetal.mm:3727` (+ `:3985, :4478, :4935, :5169`; dtor/`invalidateVBOCache:4192`) |
| H-5 | high | one-off `oitPipelineForVD`/`shadowPipelineForVD` pipelines (+ descriptor) **per surface-stride transparent/shadow draw** (transient local, never cached/released) | `RendererMetal.mm:3669, 3452, 3790-3813, 4030-4046` |
| M-17 | medium | full set of pipelines/functions/libraries **per MSAA change** (`setSampleCount` nils/overwrites +1 ivars w/o release) | `RendererMetal.mm:283-304` |
| M-18 | medium | previous `_batchBuffer` on every growth (+ at teardown) | `RendererMetal.mm:2892-2895` |
| M-19 | medium | **the destructor** releases only `_lineBuffer`/`_upscaler`; leaks all scene targets, pass descriptors, every pipeline/function, samplers, depth-stencil states, RT accel-structures, atlas | `~RendererMetal() RendererMetal.mm:306-318` |
| M-20 | medium | fallback VBO pipeline (+ `MTLVertexDescriptor` `vd`) per draw for unmatched vertex layouts | `RendererMetal.mm:3822-3846, 3731; 4052-4076, 3999` |
| M-21 | medium | temporary index `MTLBuffer` per `drawElements` client-pointer call | `RendererMetal.mm:2468-2481` |
| L-39 | low | `_captureTex` / `_labelAtlas` previous texture on resize/regrow (+ teardown) | `RendererMetal.mm:2063-2069, 5406-5415` |
| L-40 | low | cap-mark pipeline (+ descriptors) when interior-cap stride changes | `RendererMetal.mm:3912-3933, 4156` |
| L-41 | low | RT triangle proto-AS temp vertex buffer `tb` | `RendererMetal.mm:1601-1614` |
| L-42 | low | `buildAccelStructure` scratch buffer (every AS build) | `RendererMetal.mm:1490-1499` |

**Also in `layer0/MetalShaderMgr.mm`** (note: this class is currently *dead code* — see I-61 — so these are latent until it's wired up, but should be fixed before it is):
- **M-22** — class has **no destructor**; cached `MTLFunction`/`MTLRenderPipelineState`/`MTLLibrary` all leak. `MetalShaderMgr.h:39-53`.
- **L-43** — `MTLCompileOptions` never released. `MetalShaderMgr.mm:133`.
- **L-44** — `MTLRenderPipelineDescriptor` never released on any path (per cache miss). `MetalShaderMgr.mm:232-261`.
- **L-45** — checks the `NSError**` out-param instead of the return value → drops a valid library/pipeline that compiled with warnings (Apple's convention: error is only meaningful when the return is nil). `MetalShaderMgr.mm:49-54`.

**AppKit one-shot leaks** (`layer5/main_appkit.mm`, MRC; tiny — one per launch, listed for completeness): `NSOpenGLPixelFormat` at `:317-322` (L-27) and `:643-644` (L-28); gratuitous unbalanced `-retain` on an `NSString` at `:1239-1240` (I-60).

**Fix pattern:** for per-frame `alloc/init` descriptors use the autoreleased convenience constructors and/or wrap the per-frame body in `@autoreleasepool {}`; cache the invariant depth-stencil/pipeline states as ivars (their descriptors never vary); `[old release]` before every ivar reassignment; iterate-and-release the STL-held Metal objects in `invalidateVBOCache`/destructor before `clear()`; give `MetalShaderMgr` a destructor.

---

## Theme 2 — `GL_POLYGON`/`GL_QUADS` render as a single triangle on the Metal backend

**Single root cause, many symptoms.** When the fork replaced legacy `glBegin(GL_POLYGON/GL_QUADS)/glEnd()` with `ImmBatch`, the Metal path in `ImmBatch::endRenderer()` (`layerGraphics/ImmediateHelper.h:139-160`) maps the GL mode to `pymol::PrimitiveType` with a `switch` that has **no case for `GL_POLYGON` or `GL_QUADS`** (the enum in `layerGraphics/Renderer.h:7-15` has no `Polygon` at all). Both fall through to `default: Triangles`, so a 4-vertex quad is drawn as **one triangle — the 4th vertex is silently dropped**. (`RendererMetal::endBatch` *does* correctly expand `Quads`→2 triangles at `RendererMetal.mm:2875-2888`, but it never receives `Quads` because the helper down-converts first.)

Confirmed symptom sites (all the fork's 2D UI/text chrome, on the Metal backend that is RayMol's primary renderer):

| # | Sev | Affected UI |
|---|-----|-------------|
| H-1 / L-34 | high/low | Popup menu backgrounds/borders & selected-item highlight; selection-mode buttons (`draw_button`) — `layer4/PopUp.cpp` (12 sites), `layer3/Executive.cpp` (4) |
| M-12 | medium | Scrollbar segments/handles — `layer1/ScrollBar.cpp:104-274` |
| M-13 | medium | Movie/control-bar button fills & borders — `layer1/Control.cpp:509-846` |
| M-14 | medium | Sequence-viewer highlight/selection boxes & coverage bars — `layer1/Seq.cpp:475-693` |
| M-15 | medium | Wizard buttons incl. the per-vertex "rainbow" swatch — `layer1/Wizard.cpp:598-669` |
| M-16 | medium | Movie panel trailing fill — `layer1/Movie.cpp:1765-1772` |
| M-9/M-11 | medium | `Block::fill` panel rectangles + **text-picking quads** (`Character.cpp:275`) → half each glyph is unpickable |

A closely related defect: **L-34** — `ImmBatch::begin()` inherits the current GL color via `glGetFloatv(GL_CURRENT_COLOR)` only when `!s_renderer`, so on the Metal path colorless batches that relied on a preceding `glColor3fv` (e.g. the selected popup highlight, `PopUp.cpp:795`→`:811`) render **white**.

**Important caveat — verifier disagreement on reachability.** Independent verifiers split on whether the Metal `Renderer` is actually active during 2D/ortho UI drawing. The *confirmed* findings traced an active path (`ImmBatch_SetActiveRenderer` in `main_appkit.mm:856` / the SwiftUI bridge); two *rejected* duplicates argued `s_renderer` is null during ortho draw so the branch is dead. **This is the single cheapest thing to resolve empirically:** open the running app and look at a popup menu, a scrollbar, and a sequence-viewer highlight. If they render as half-filled triangles, the whole cluster is live and one fix (add `case GL_POLYGON → TriangleFan` / `GL_QUADS → Quads` in `endRenderer`, plus triangulation) clears all of it.

---

## Theme 3 — Concurrency

- **H-7 — MCP tools call the PyMOL `cmd` API from HTTP request threads.** `modules/raymol_mcp/tools.py:59-134`. All tool bodies (`do`, `sync`, `exec`, `png(ray=1)`, `get_view`…) run on `http.server` handler threads, racing the main-thread Metal render loop. The app's own code documents this is unsafe (`PyMOLEngine.swift:619-620`: the core's `PAutoBlock`/GIL model "is NOT safe to call off the main thread"). **Nuance** (from the verifier that rejected the over-broad "no lock at all" version): a Python-level API lock *does* exist (`pymol.lock_api` RLock via `LockCM`), so native calls are serialized at the Python level — but that lock does **not** synchronize against the main thread's live rendering / `PAutoBlock`. Net: real risk of non-deterministic native crashes/corruption, especially `cmd.png(ray=1)` concurrent with the live view. **Fix:** marshal every tool call onto the main runloop (the channel `runPython` already uses) and block the request thread on a future.
- **M-25 — `Process` + single shared `Pipe` deadlock.** `MCPServerManager.swift:226-237` (`runClaude`): wires stdout+stderr to one pipe, calls `waitUntilExit()` *before* draining it. If `claude` emits >~64 KB the child blocks on write while the parent blocks forever — the connect flow hangs and the completion handler never fires. **Fix:** read the pipe to EOF *then* wait.
- **L-50 — `_sessions` dict mutated from request threads + sweeper with no lock.** `raymol_mcp/server.py:54-196`. GIL prevents corruption but not lost updates / double `client_disconnected` emission / pruning a still-active session. **Fix:** one sessions lock; check-and-pop atomically before emitting disconnect.
- **L-38 — capture-texture data race.** `RendererMetal.mm:2061-2083`: a command-buffer completion handler reads the single reusable `_captureTex` ivar; a second capture within a frame or two can blit into it while the prior handler still reads it. Rare torn/garbled PNG. **Fix:** per-capture staging texture / double-buffer.
- **L-57 — `MCPBridge.proxy` late completion on 120 s timeout** writes static `sessionId` from the URLSession queue while the next request reads it. `MCPBridge.swift:66-78`. **Fix:** `task.cancel()` on timeout; guard `sessionId`.

---

## Theme 4 — Crashes & functional bugs

- **H-6 — Four File-menu commands send unrecognized selectors (ObjC exception / crash).** `modules/pymol/appkit_menus.py:261-273`. PyObjC maps trailing `_` → `:`, but the action strings carry an *extra* underscore: `'fetchPDB_:'`, `'saveSessionQuick_:'`, `'exportPNG_:'`, `'runScript_:'` name non-existent selectors. Items stay enabled (`setAutoenablesItems_(False)` + explicit target), so **Get PDB…, Save Session, Export PNG, Run Script…** raise an `NSException` across the ObjC/Python boundary on click. Correct siblings `openFile:`/`saveSession:` prove the convention. **Fix:** drop the spurious underscore.
- **M-26 — Stale `anchorIndex` → array out-of-bounds force-trap on Shift-click.** `swiftui/.../SequencePanel.swift:248-250`. `flat[lo...hi]` mixes a fresh `idx` with a stale anchor `a`; if `engine.sequences` shrank (object removed) since the anchor click, `a >= flat.count` crashes. **Fix:** clamp to `flat.count-1` and invalidate the anchor on object-list change.
- **M-23 — Theme preview can destroy the live session unrecoverably.** `modules/pymol/appkit_theme_preview.py:23-44`. If the session snapshot raises, `_saved=None` but the code **still** runs `cmd.disable("all")` and shows only the preview; `restore()` with `_saved is None` never re-enables anything → the user's whole scene is hidden with no restore path. **Fix:** bail out before mutating the scene when the snapshot failed.
- **L-46 — Tab completion is dead.** `appkit_command_panel.py:184-192` calls `cmd.complete(text)`, which doesn't exist; the `AttributeError` is swallowed. **Fix:** use `cmd._parser.complete(text)`.
- **L-36 — `readPixels` `getBytes` on the (framebufferOnly/Private) drawable texture.** `RendererMetal.mm:2997-3022`: Metal validation assert / garbage, no row alignment, no command-buffer sync. Latent until the GL `glReadPixels` compatibility path is exercised. **Fix:** read from a Shared `_sceneColor`/`_captureTex` after commit+wait.
- **L-47 — Log truncation uses Python code-point lengths against UTF-16 `NSTextStorage` offsets** → mis-aligned delete (garbles log) when a line has non-BMP chars (emoji). `appkit_command_panel.py:103-113`.
- **L-56 — Selection-expression injection via `'''`.** `PyMOLEngine.swift:1060-1077`: user/agent selection text is spliced into a raw triple-quoted Python literal after stripping only backslashes; an embedded `'''` ends the literal early → at best a silent `SyntaxError` no-op, at worst arbitrary Python in the embedded interpreter. Reachable from the selection builder and the AI copilot. (Object/file *names* on similar paths were checked and **rejected** — they're sanitized by the C++ core; see false-positives FP-11/FP-12.) **Fix:** don't build source by interpolation — base64/JSON-encode and decode in a fixed helper.

---

## Theme 5 — Regressions from removing immediate-mode rendering

- **L-52 — `defer_builds_mode = 5` makes lines, sticks/cylinders, and ribbons disappear.** `layer2/CoordSet.cpp:1355-1372` still routes mode-5 to `RepWireBondRenderImmediate`/`RepCylBondRenderImmediate`/`RepRibbonRenderImmediate`, which were gutted to empty no-ops (`RepWireBond.cpp:266`, `RepCylBond.cpp:916`, `RepRibbon.cpp:594`), then `return`s before the shader path. Gated behind a non-default setting, but silent when hit (spheres/nonbonded still draw). **Fix:** let mode 5 fall through to the CGO/shader path, or make the no-op functions delegate.
- **I-64 — non-shader mesh fallback is now a no-op** (`RepMesh.cpp:378-390`, still reached via `RepMeshRasterRender:460`) + dead `v/vc/n/G` locals (`-Wunused`).
- **L-53 — `GadgetSet` builds `StdCGO`/`PickCGO` in the no-shader branch but the draw is `if (use_shader)`-gated** → color ramps etc. don't render with shaders off; wasted work (freed correctly, no leak). `layer2/GadgetSet.cpp:305-330`.
- **L-24 — `ImmBatch::begin()` clobbers a color set by `color4f()` before `begin()` (GL path only).** `ImmediateHelper.h:34-51`. `SphereRender` sets the color once then loops `begin()` (`layer0/Sphere.cpp:676`), so the CGO-sphere **pick** color (`CGOGL.cpp:2170`) is overwritten by stale `GL_CURRENT_COLOR` → wrong picking for CGO spheres on desktop GL builds.
- **L-33 — CGO batch path doesn't seed color when both color & pick arrays are absent** → stale color from a prior unrelated batch. `layer1/CGOGL.cpp:627-653` (cosmetic).

---

## Theme 6 — OpenMP surface path (Linux/CI builds; macOS default = off)

- **L-54 — parallel solvent-dot loop `return true` unconditionally**, ignoring `G->Interrupt` and helper return values that the serial reference propagates. `layer2/RepSurface.cpp:4632-4645`. Partly mitigated by a later interrupt re-check, so practical effect ≈ masking helper failures.
- **L-55 — `std::vector::insert` can `throw` out of an `#pragma omp parallel` block = UB / `std::terminate`** under memory pressure. `RepSurface.cpp:4621-4624`. **Fix:** try/catch inside the region, set a shared error flag.

---

## Theme 7 — Packaging / build scripts (`scripts/`)

These don't affect the running product but can **ship a broken bundle silently**:

- **M-8 — `install_name_tool` retry failure swallowed** (return code of the 2nd attempt ignored) → stale baked-in `/opt/homebrew` paths survive; only dependency refs are later verified, not `-id`/`-add_rpath`. `bundle_app.py:134-149`. (Sibling `bundle_macos_dylibs.py:152-161` raises correctly — copy that.)
- **L-29 — every `codesign` call ignores its return code** → a bundle with a failed signature is reported as success and fails Gatekeeper/dyld on a clean machine. `bundle_app.py:423-467`.
- **L-31 — `detect_python_version` lacks the try/except every other `otool` call has** → unhandled traceback instead of clean exit. `bundle_app.py:111-122`.
- **L-32 — dylibs copied by basename**; two distinct Homebrew dylibs sharing a basename collide (first wins, both load commands point to it). `bundle_app.py:299-328`.
- **L-30 — unquoted `find` command-substitution word-splits** → numpy `.so` renames silently fail if the checkout path contains a space. `build_numpy_ios.sh:98-100`.

---

## Theme 8 — Performance (no crash/leak, but real cost)

- **M-10 — `retainInterleavedCPUCopy()` runs unconditionally in `evaluate()`** → a full 2nd CPU copy of every VBO, only ever read on the Metal path, **dead weight (~2× geometry RAM) on the OpenGL desktop build.** `layerGraphics/gl/GLVertexBuffer.cpp:299-303`.
- **L-37 — OIT depth-stencil states allocated per transparent draw call** (same descriptor every time) — the performance face of H-3. `RendererMetal.mm:4088-4092`.
- **L-48 — sequence panel rebuilds a full `str(sequences)` snapshot + `get_model` for every object every 500 ms** regardless of change. `appkit_sequence_panel.py:297-303`.
- **L-58 — `ColorPicker` fires `set_color`+recolor on every continuous drag tick** (no debounce, unlike `LabeledSlider`). `ObjectPanel.swift:1402-1406` (and 1442, 1908, 1934).
- **L-59 — movie export renders each (possibly ray-traced) frame synchronously on the main thread + a `usleep` busy-wait** → UI beachballs for the whole export. `MovieExportSheet.swift:120-132`.
- **L-51 / L-35 — minor:** `capture_viewport` width/height unbounded → CPU ray-trace DoS (`tools.py:121-128`); unused `selection_visible_only` flag in `ExecutiveGetSelectionCoords` (`Executive.cpp:8605`).

---

## Theme 9 — Informational / latent

- **I-61 — the entire `data/shaders_metal/*.metal` set is dead code.** `MetalShaderMgr` (its only loader) is never instantiated; the live renderer uses its own inline MSL strings. So shader-correctness items below are latent. This caps their runtime severity.
- **I-62 — `get_oit_weight` `pow(1-depth, 3)` can go NaN** for `depth>1` (unused today). `pymol_metal_common.h:123-125`.
- **I-63 — 10 duplicate identical `GL_*` `#define`s** in the `_PYMOL_NO_OPENGL` stub (benign; future-mismatch hazard). `layer0/os_gl.h:73-299`.
- **I-65 — misleading comment**: `runCommand` says heavy ops run "off-main" but `runHeavy` correctly stays on the main queue — risk is a future maintainer "fixing" it and corrupting the interpreter. `PyMOLEngine.swift:582-590`.

---

## Recommended priority order

1. **Theme 1 Metal leaks** (H-2..H-5, M-17..M-21, M-19 destructor) — the only set that degrades the app during *normal use*; biggest win, especially on iPad. Add an `@autoreleasepool` around the per-frame body and cache the invariant pipeline/depth-stencil states first — those two changes kill most of it.
2. **H-6 menu-selector crash** — trivial fix, 4 user-facing commands currently broken.
3. **H-7 MCP off-main-thread `cmd` calls** — main-thread marshalling; sporadic field crashes otherwise.
4. **Theme 2 `GL_POLYGON`/`GL_QUADS`** — first *confirm reachability* in the running app (5-minute visual check), then one switch-case fix clears all UI-chrome corruption.
5. **M-26 SequencePanel OOB**, **M-23 theme-preview scene loss**, **M-25 pipe deadlock** — each a single localized fix.
6. **M-8 / L-29 packaging** — before the next release (prevent shipping a broken signed bundle).
7. Remainder (regressions behind non-default settings, perf, info) as cleanup.

---

## Appendix — 31 findings checked and **rejected** as false positives

Recorded so they aren't surfaced again. Each was dismissed for a verified reason:

**Unreachable / dead code:** RT-tessellation & `rtAppendVBOTris` OOB reads (fixed 8-vert/36-idx invariant; PyMOL-generated indices) · `getViewportRect` scale (only internal grid callers) · `MetalShaderMgr` second-load leak & most shader-math NaN items (loader never instantiated) · `CObject::render` dummy box (no bare `CObject` ever constructed) · `main.cpp` `GL_LINE_LOOP` fallthrough (excluded from Metal build, GL path uses `s_renderer==null`) · several "ImmBatch mode mis-map" duplicates judged dead on the ortho path (**note the Theme-2 reachability split above**) · `metalConfigDone` second-instance gating (single-instance only).

**Already guarded:** MCP "no serialization" (the `pymol.lock_api` RLock exists) · `run_python` sandbox & AUTOTRUST (by-design, loopback+token+approval) · `search_pdb`/`_num`/inspector-hex/clipboard exception cases (wrapped in try/except or curated inputs) · object/file **name** injection in `PyMOLEngine`/`ObjectPanel` (sanitized by `ObjectMakeValidName` in the core) · `LabeledSlider` work-item (captures by value, idempotent) · ray-overlay & several Python timer/`_retained` "leaks" (single one-time init path; timers retained by the runloop; GIL-atomic globals).

**Faithful upstream port (not fork-introduced):** `line.metal` / `sphere.metal` / `connector.metal` divide-by-zero (1:1 ports of guarded upstream GLSL) · `externing.py new_list` typo (pre-existing, no effect).

**Correct as written / wrong premise:** grid-mode pick slot includes non-molecule objects *on purpose* (keeps slot order aligned with the C++ layout — the suggested "fix" would introduce the bug) · `bundle_app.py` no-rollback (regenerable dev-tool artifact).
