# Adaptive Cartoon LOD + Display-Aware Upscale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adaptively raise cartoon tessellation when zoomed in (debounced whole-object rebuild) and auto-enable reduced-res upscale only on Retina displays.

**Architecture:** Pure LOD math (Å/px → sampling with hysteresis; Retina check) is isolated and unit-tested standalone. The debounce timer + triggers live in Swift (`MetalViewport`/`PyMOLEngine`) because RayMol renders on-demand (no per-frame poll at settle). Settings live in the core; the renderer already exposes `_upscaleEnabled`.

**Tech Stack:** C++17 core (`layer1`), Metal renderer (`layerGraphics/metal`), SwiftUI app (`swiftui/PyMOLViewer`), `swift` CLI for standalone unit tests.

## Global Constraints

- Two-stage build every time (macos_swiftui_build_verify): `bash swiftui/build_macos.sh` (core) **then** `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd build`. xcodebuild alone links a stale `libpymol_core.a`.
- Setting indices are contiguous; next free after `822 metal_ssao_cartoon` and `823 metal_shadow_bias` is **824**.
- New settings default to preserving current behavior EXCEPT `cartoon_sampling_dynamic` (default on) and `metal_upscale` auto (default 2) — both approved.
- Feature branch already checked out: `feat/adaptive-cartoon-lod` (off master `c9ab45f65`). Never push to master; PR at the end.
- Verify functionally via host offscreen render (`PYMOL_AUTOCMD` + `PYMOL_AUTOEXPORT`) and the mac-vm-test VM. This codebase verifies rendering features functionally, not via GL unit tests.

---

### Task 1: Add settings

**Files:**
- Modify: `layer1/SettingInfo.h` (after line 909 `metal_shadows` block / the 823 line)

**Interfaces:**
- Produces: `cSetting_cartoon_sampling_dynamic` (bool), `cSetting_cartoon_sampling_max` (int), `cSetting_metal_upscale` (now int 0..2).

- [ ] **Step 1: Change `metal_upscale` from bool to int (0=off,1=on,2=auto), default 2**

In `layer1/SettingInfo.h`, replace the existing line (currently `REC_b( 814, metal_upscale ... , false )`):
```c
  REC_i( 814, metal_upscale                            , global    , 2, 0, 2 ), /* Metal: reduced-res render + upscale. 0=off, 1=on, 2=auto (on only on Retina displays where the blur is hidden). */
```

- [ ] **Step 2: Add the two cartoon LOD settings after index 823 (`metal_shadow_bias`)**
```c
  REC_b( 824, cartoon_sampling_dynamic                 , global    , true ), /* Adaptively raise/lower cartoon_sampling with zoom (debounced whole-object rebuild). Off = static cartoon_sampling. */
  REC_i( 825, cartoon_sampling_max                     , global    , -1 ),   /* Detail ceiling used by cartoon_sampling_dynamic when zoomed in. -1 = auto (scaled down by atom count). */
```

- [ ] **Step 3: Build the core**

Run: `bash swiftui/build_macos.sh 2>&1 | tail -2`
Expected: ends with `Built target pymol_core` / `arm64` (no errors).

- [ ] **Step 4: Verify the setting names resolve (compile-time)**

Run: `grep -nE "cSetting_cartoon_sampling_dynamic|cSetting_cartoon_sampling_max|cSetting_metal_upscale" build_macos_swiftui/*/SettingInfo.h 2>/dev/null || grep -c "cartoon_sampling_dynamic" layer1/SettingInfo.h`
Expected: nonzero (the cSetting_ enums are generated from these lines).

- [ ] **Step 5: Commit**
```bash
git add layer1/SettingInfo.h
git commit -m "feat(metal): add cartoon_sampling_dynamic/_max settings; metal_upscale -> int 0/1/2"
```

---

### Task 2: Pure LOD math (standalone unit-tested), then place in app source

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/CartoonLOD.swift`
- Test (throwaway, do not commit): `/tmp/CartoonLODTest.swift`

**Interfaces:**
- Produces (Swift, all pure/static, no state):
  - `CartoonLOD.angstromPerPixel(cameraDistance: Float, fovDegrees: Float, viewportHeightPx: Float) -> Float`
  - `CartoonLOD.targetSampling(angstromPerPixel: Float, maxSampling: Int, current: Int) -> Int`  (buckets + hysteresis)
  - `CartoonLOD.autoUpscale(backingScale: CGFloat) -> Bool`  (`>= 2.0`)

- [ ] **Step 1: Write the failing standalone test**

Create `/tmp/CartoonLODTest.swift` (contains a copy of the functions so it compiles alone; you'll paste the same bodies into the real file in Step 3):
```swift
import Foundation

enum CartoonLOD {
    static func angstromPerPixel(cameraDistance: Float, fovDegrees: Float, viewportHeightPx: Float) -> Float {
        guard viewportHeightPx >= 1 else { return 1e9 }
        let halfTan = tan(fovDegrees * 0.5 * .pi / 180)
        return (2 * abs(cameraDistance) * halfTan) / viewportHeightPx
    }
    // Coarse->fine buckets by Å/px upper bound. Hysteresis: only move to a
    // different bucket when past its boundary by a 20% margin relative to the
    // direction of change, so hovering a threshold does not thrash.
    static func targetSampling(angstromPerPixel a: Float, maxSampling: Int, current: Int) -> Int {
        let edges: [(Float, Int)] = [(0.05, maxSampling), (0.10, 12), (0.25, 8), (0.50, 5)]
        // pick raw bucket: first edge whose upper bound a < edge.0 ... else floor 3
        func raw(_ x: Float) -> Int {
            for (ub, s) in edges { if x < ub { return s } }
            return 3
        }
        let t = raw(a)
        if t == current { return current }
        // hysteresis: require a to be 20% past the boundary in the move direction
        let margin: Float = (t > current) ? 0.83 : 1.20  // finer needs a smaller, coarser needs a larger
        let a2 = a * margin
        return raw(a2) == t ? t : current
    }
    static func autoUpscale(backingScale: CGFloat) -> Bool { backingScale >= 2.0 }
}

// --- asserts ---
func eq(_ a: Int, _ b: Int, _ m: String) { assert(a == b, m); print("ok: \(m)") }
// zoomed WAY in (tiny Å/px) -> maxSampling
eq(CartoonLOD.targetSampling(angstromPerPixel: 0.01, maxSampling: 18, current: 3), 18, "zoom-in -> max")
// zoomed out (large Å/px) -> floor 3
eq(CartoonLOD.targetSampling(angstromPerPixel: 2.0, maxSampling: 18, current: 12), 3, "zoom-out -> floor")
// mid
eq(CartoonLOD.targetSampling(angstromPerPixel: 0.15, maxSampling: 18, current: 3), 8, "mid -> 8")
// hysteresis: sitting just inside a boundary from current does not flip
eq(CartoonLOD.targetSampling(angstromPerPixel: 0.249, maxSampling: 18, current: 5), 5, "hysteresis holds")
// Å/px sanity: closer camera => smaller Å/px
assert(CartoonLOD.angstromPerPixel(cameraDistance: 20, fovDegrees: 20, viewportHeightPx: 1000)
     < CartoonLOD.angstromPerPixel(cameraDistance: 200, fovDegrees: 20, viewportHeightPx: 1000), "closer=finer")
print("ok: angstromPerPixel monotonic")
assert(CartoonLOD.autoUpscale(backingScale: 2.0) && !CartoonLOD.autoUpscale(backingScale: 1.0), "retina gate")
print("ALL PASS")
```

- [ ] **Step 2: Run it and confirm it FAILS first (before you trust it), then passes**

Run: `swift /tmp/CartoonLODTest.swift`
Expected: prints `ALL PASS`. If any `assert` fires, fix the function bodies until it passes. (Deliberately break one edge value, re-run to see it fail, then restore — confirms the test bites.)

- [ ] **Step 3: Create the real file with the SAME `CartoonLOD` enum**

Create `swiftui/PyMOLViewer/Shared/CartoonLOD.swift` containing exactly the `import Foundation` + `enum CartoonLOD { ... }` block from Step 1 (no test code). Add it to the Xcode project (the target uses explicit file refs — add via pbxproj or the inline-source pattern; see how `MetalViewport.swift` is referenced and mirror it).

- [ ] **Step 4: Build the app to confirm the file compiles/links**

Run: `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd build 2>&1 | grep -c "BUILD SUCCEEDED"`
Expected: `1`.

- [ ] **Step 5: Commit**
```bash
git add swiftui/PyMOLViewer/Shared/CartoonLOD.swift swiftui/PyMOLViewer.xcodeproj/project.pbxproj
git commit -m "feat(metal): pure CartoonLOD math (Å/px, sampling buckets+hysteresis, retina gate)"
```

---

### Task 3: Wire zoom-adaptive sampling (Swift debounce → rebuild)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (add helpers)
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (camera-settle debounce)

**Interfaces:**
- Consumes: `CartoonLOD.*` (Task 2); `cmd` view via engine; `cSetting_cartoon_sampling*` (Task 1).
- Produces: `PyMOLEngine.applyDynamicCartoonSampling()` (reads view+fov+viewport, computes target, sets `cartoon_sampling` + `rebuild` if changed and `cartoon_sampling_dynamic` is on).

- [ ] **Step 1: Add engine helpers**

In `PyMOLEngine.swift`, add:
```swift
// Cached to avoid redundant rebuilds.
private var lastAppliedSampling: Int = -1

/// Compute the zoom-adaptive cartoon_sampling and rebuild if it changed.
/// No-op unless cartoon_sampling_dynamic is on. Call on the main thread when
/// the camera has settled (debounced by the caller).
func applyDynamicCartoonSampling(viewportHeightPx: Float) {
    guard runPythonInt("int(cmd.get_setting_int('cartoon_sampling_dynamic'))") == 1 else { return }
    // camera distance ~ magnitude of the view translation z (18-float get_view: v[11])
    let v = runPythonFloats("list(cmd.get_view())")   // 18 floats
    guard v.count >= 18 else { return }
    let camDist = abs(v[11])
    let fov = runPythonFloat("float(cmd.get_setting_float('field_of_view'))")
    var maxS = runPythonInt("int(cmd.get_setting_int('cartoon_sampling_max'))")
    if maxS < 0 {   // auto: scale down by atom count
        let n = runPythonInt("cmd.count_atoms('polymer')")
        maxS = n < 10000 ? 18 : (n < 50000 ? 12 : (n < 200000 ? 8 : 5))
    }
    let cur = lastAppliedSampling > 0 ? lastAppliedSampling
              : runPythonInt("int(cmd.get_setting_int('cartoon_sampling'))")
    let app = CartoonLOD.angstromPerPixel(cameraDistance: camDist, fovDegrees: fov,
                                          viewportHeightPx: viewportHeightPx)
    let target = CartoonLOD.targetSampling(angstromPerPixel: app, maxSampling: maxS, current: cur)
    guard target != cur else { return }
    lastAppliedSampling = target
    runPython("cmd.set('cartoon_sampling', \(target)); cmd.rebuild()")
}
```
(If `runPythonInt/Float/Floats` helpers don't exist, add thin wrappers over the existing `runPython` that parse the returned string; mirror the existing bridge helpers.)

- [ ] **Step 2: Add a debounced camera-settle hook in MetalViewport**

In `MetalViewport.swift`, where camera/gesture changes occur (the same places that call `engine.button`/`engine.drag`/`zoomBy`), after applying the camera change, schedule:
```swift
private var lodWork: DispatchWorkItem?
func scheduleLODUpdate() {
    lodWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        let h = Float(self.mtkView.drawableSize.height)
        self.engine.applyDynamicCartoonSampling(viewportHeightPx: h)
    }
    lodWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)  // 200ms settle
}
```
Call `scheduleLODUpdate()` from the zoom path (`zoomBy`, magnification/scroll handlers) and at the end of a rotate/pan drag. (Zoom is the primary driver; rotate/pan also change Å/px negligibly, so calling on any camera change is fine and the debounce coalesces.)

- [ ] **Step 3: Build (core already built in Task 1; app only)**

Run: `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd build 2>&1 | grep -c "BUILD SUCCEEDED"`
Expected: `1`.

- [ ] **Step 4: Functional verify — sampling rises when zoomed in**

Launch with MCP (`defaults write io.raymol.RayMol raymol.mcp.enabled -bool true`; `open -n` the app), then over MCP:
```
run_pymol_command: load .../1ubq.pdb, async=0
run_pymol_command: show cartoon
run_python: cmd.zoom('all'); print(cmd.get_setting_int('cartoon_sampling'))   # baseline bucket
run_python: cmd.zoom('resi 1-6', -8)   # extreme zoom-in on a strand
# trigger the debounce path the way the viewport would, then read back:
run_python: import time; e=None
```
Because the debounce lives in the view layer, verify the *math* deterministically instead: 
```
run_python: v=cmd.get_view(); import math; d=abs(v[11]); fov=cmd.get_setting_float('field_of_view'); app=(2*d*math.tan(math.radians(fov)/2))/1200.0; print('ang/px',app)
```
Expected: `ang/px` is much smaller after the zoom-in than after `zoom all` (confirms the metric tracks zoom). Then confirm `applyDynamicCartoonSampling` raised sampling by rendering (Step 5).

- [ ] **Step 5: Functional verify — visible crispness A/B (host offscreen)**

Render a zoomed β-strand with dynamic ON vs OFF and confirm ON is finer:
```bash
# ON (default)
PYMOL_AUTOCMD="load 1ubq.pdb; show cartoon; orient resi 1-16; zoom resi 1-16,-6" \
PYMOL_AUTOEXPORT="/tmp/lod_on.png,1400,1050" open -n <app>
# OFF
PYMOL_AUTOCMD="set cartoon_sampling_dynamic,0; load 1ubq.pdb; show cartoon; orient resi 1-16; zoom resi 1-16,-6" \
PYMOL_AUTOEXPORT="/tmp/lod_off.png,1400,1050" open -n <app>
```
Expected: with dynamic ON the zoomed strand mesh is visibly finer/smoother than OFF (the debounce won't fire in the one-shot export path, so ALSO verify by directly `set cartoon_sampling,18; rebuild` matches the ON look — proving the rebuild path works; the live debounce is exercised interactively in Task 5/VM).

- [ ] **Step 6: Commit**
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewer/Shared/MetalViewport.swift
git commit -m "feat(metal): zoom-adaptive cartoon_sampling via debounced rebuild"
```

---

### Task 4: Display-aware upscale (metal_upscale auto = Retina)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (backing-scale detection + screen-change observer)
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (push effective upscale)
- Modify: `layer1/SceneRender.cpp` (resolve `metal_upscale==2` using a renderer-held retina flag)
- Modify: `layerGraphics/metal/RendererMetal.h` / `.mm` (`_displayIsRetina` + `setDisplayIsRetina`)

**Interfaces:**
- Consumes: `CartoonLOD.autoUpscale(backingScale:)` (Task 2); `cSetting_metal_upscale` int (Task 1).
- Produces: `Renderer::setDisplayIsRetina(bool)`; effective upscale = `(metal_upscale==1) || (metal_upscale==2 && displayIsRetina)`.

- [ ] **Step 1: Renderer holds the retina flag**

`RendererMetal.h`: add `bool _displayIsRetina = true;` and `void setDisplayIsRetina(bool r) override;`. `Renderer.h`: `virtual void setDisplayIsRetina(bool) {}`. `RendererMetal.mm`: `void RendererMetal::setDisplayIsRetina(bool r){ _displayIsRetina = r; }`.

- [ ] **Step 2: Resolve auto where `_upscaleEnabled` is currently set**

In `SceneRender.cpp` where `metal_upscale` is read for `setDesiredUpscale`/`setPostParams` (grep `metal_upscale`), change:
```cpp
int mu = SettingGetGlobal_i(G, cSetting_metal_upscale);
bool upscale = (mu == 1) || (mu == 2 && G->Renderer->displayIsRetina()); // add a getter, or pass through setPostParams' upscaleEnabled
```
(If `metal_upscale` was read as bool, switch to `_i`. Keep the existing plumbing to `_upscaleEnabled`.)

- [ ] **Step 3: Swift pushes backing scale on launch + screen change**

`MetalViewport.swift` (`makeNSView` / coordinator): compute `CartoonLOD.autoUpscale(backingScale: view.window?.screen?.backingScaleFactor ?? 2)`, call `engine.setDisplayIsRetina(_:)`. Observe `NSWindow.didChangeScreenNotification` and `NSView` `viewDidChangeBackingProperties()` → recompute + push. Add `PyMOLEngine.setDisplayIsRetina(_ r: Bool)` → bridge → `Renderer::setDisplayIsRetina`.

- [ ] **Step 4: Build (core + app — SceneRender/Renderer changed)**

Run: `bash swiftui/build_macos.sh 2>&1 | tail -1 && xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd build 2>&1 | grep -c "BUILD SUCCEEDED"`
Expected: `arm64` then `1`.

- [ ] **Step 5: Functional verify**

- `set metal_upscale, 0` → full-res (no upscale) regardless of display.
- `set metal_upscale, 1` → upscale on regardless.
- `set metal_upscale, 2` (default) on the built-in Retina display → upscale on; the auto path is exercised. (Non-Retina external verification is manual/host — note it; the VM is single Retina-like display.)

Confirm via `_renderScale`: add a one-line `NSLog` of the effective upscale decision, or infer from a render (upscaled frame is softer). Read back `cmd.get_setting_int('metal_upscale')` == 2.

- [ ] **Step 6: Commit**
```bash
git add layer1/SceneRender.cpp layerGraphics/Renderer.h layerGraphics/metal/RendererMetal.h layerGraphics/metal/RendererMetal.mm swiftui/PyMOLViewer/Shared/MetalViewport.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(metal): metal_upscale auto (2) enables reduced-res upscale only on Retina displays"
```

---

### Task 5: Integration verification + regression + PR

**Files:** none (verification only)

- [ ] **Step 1: Regression — both features off = identical to master**

Render 1ubq (cartoon, shadows on) with `set cartoon_sampling_dynamic,0` and `set metal_upscale,0`; A/B vs a master build. Expect ~0% pixel diff.

- [ ] **Step 2: Adaptive A/B across zoom + angles (host offscreen)**

For 1ubq, 1hho, 1aon: zoom out (expect low sampling, cheap) and zoom in (expect high sampling, crisp). Confirm no triangle acne at zoom-in and no mid-drag hitch (interactive). Confirm 1aon rebuild stays bounded (<~200 ms) via timing.

- [ ] **Step 3: mac-vm-test VM smoke**

Per the mac-vm-test skill: install the app in a fresh VM, load 1ubq, `show cartoon`, drive a zoom, confirm it renders crisp with no crash; offscreen-export a frame and pull it.

- [ ] **Step 4: Push branch + open PR (REST API — gh pr create/merge hit the classic-Projects GraphQL bug)**
```bash
git push -u origin feat/adaptive-cartoon-lod
gh api -X POST repos/javierbq/RayMol/pulls -f title="..." -f head="feat/adaptive-cartoon-lod" -f base="master" -F body=@/tmp/pr_body.md
```

- [ ] **Step 5: Update memory** — append the adaptive-LOD design + on-demand-render timer gotcha + benchmark to `fix_cartoon_shadow_triangles.md` or a new memory, and the MEMORY.md index.

---

## Self-review notes
- Spec coverage: Component A → Tasks 1–3; Component B → Tasks 1,4; testing → Task 5. Non-goals (no per-region/GPU rewrite) respected.
- The `runPythonInt/Float/Floats` helpers are assumed; if absent, Task 3 Step 1 says to add thin wrappers (not a placeholder — explicit instruction).
- Bucket thresholds are the spec's starting values; Task 5 Step 2 calibrates.
- Camera-settle: solved via Swift 200 ms debounce (on-demand render can't per-frame poll) — matches spec ownership.
