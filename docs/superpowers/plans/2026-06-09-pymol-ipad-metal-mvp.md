# PyMOL iPad (Metal) MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PyMOLViewer SwiftUI app launch on the iOS Simulator, render a real structure through the existing Metal backend, and support touch interaction + tap-to-select.

**Architecture:** The Metal renderer (`pymol::RendererMetal`), Metal scene driver (`SceneRenderMetal`), and CPU picking (`metal_pick.py`) already exist and work on macOS (`layer5/main_appkit.mm` is the reference). This plan adds the iOS-specific glue: (1) embed + boot CPython 3.13 from the BeeWare `Python.xcframework` following BeeWare's proven packaging, (2) construct `RendererMetal` on iOS and hand it the per-frame `CAMetalDrawable`, (3) wire a tap to `metal_pick.pick_at`. No C++ core logic changes — only the Swift/ObjC++ bridge, the Xcode project (`project.yml`), and one rewritten bridge function.

**Tech Stack:** Swift + SwiftUI, Objective-C++ bridge (`.mm`), Metal/MetalKit, CMake-built `libpymol_core.a` (iOS-sim arm64, already built), BeeWare CPython 3.13 `Python.xcframework`, xcodegen 2.45, Xcode 26.4.

**Reference spec:** `docs/superpowers/specs/2026-06-09-pymol-ipad-metal-mvp-design.md`

---

## Verification model (read first)

This is iOS app-integration work; the project has **no unit-test harness for the app** (PyMOL's `testing/testing.py` runs against the desktop build, not the iOS app). So "test-first" here means: **define the observable acceptance check, confirm it currently fails, implement, confirm it passes** — using `xcodebuild`, `simctl`, console logs, and screenshots. This matches the repo's functional-testing convention.

**Canonical commands (used throughout). Run from the repo root unless noted.**

```bash
# Pick a simulator once (any iPad); export its name for reuse.
export SIM='iPad (A16)'
xcrun simctl boot "$SIM" 2>/dev/null || true   # ok if already booted
open -a Simulator 2>/dev/null || true

# Build the iOS app to a predictable DerivedData path.
cd swiftui
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
  -sdk iphonesimulator -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath ./build_xcode \
  build 2>&1 | tail -40
cd ..

APP=swiftui/build_xcode/Build/Products/Debug-iphonesimulator/PyMOLViewer.app
BUNDLE_ID=org.pymol.viewer

# Install + launch, capturing the app's stdout/stderr to a log.
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" 2>&1 | tee /tmp/pymol_ios.log &
sleep 6
xcrun simctl io "$SIM" screenshot /tmp/pymol_ios.png
```

**Test affordances added by this plan** (small, env-gated, harmless when the env var is unset — passed to the app via `SIMCTL_CHILD_*`):
- `PYMOL_AUTOLOAD=<bundled.cif>` → on launch, run `load <file>; hide everything; show cartoon; orient` so a screenshot has content without UI typing.
- `PYMOL_AUTOPICK=<ndcX>,<ndcY>` → after autoload, call the pick bridge at that NDC and log the resulting selected-atom count, so picking is verifiable without synthesizing a touch.

Example: `SIMCTL_CHILD_PYMOL_AUTOLOAD=1ubq.cif xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID"`

---

## File structure (what changes and why)

**Modified — Swift/ObjC++ bridge (compiled by Xcode, not in the static lib):**
- `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h` — declare 3 new C entry points: `PyMOLBridge_SetupMetalRenderer`, `PyMOLBridge_RenderMetalFrame`, `PyMOLBridge_Pick`.
- `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm` — Metal/MetalKit imports; rewrite `PyMOLBridge_InitPython` (PyConfig, 3.13); implement the 3 new functions.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — Swift wrappers: `setupMetalRenderer(view:)`, `renderMetalFrame(...)`, `pick(...)`; env-gated autoload/autopick hooks.
- `swiftui/PyMOLViewer/Shared/MetalViewport.swift` — `import UIKit`; rewrite `draw(in:)`; rewrite `handleTap` → pick.
- `swiftui/PyMOLViewer/Panels/CommandPanel.swift` — `import UIKit`.

**Modified — Xcode project generation:**
- `swiftui/project.yml` — split into per-platform targets so iOS-only phases don't touch macOS; on iOS add: Embed `Python.xcframework`; rsync stdlib; repackage `lib-dynload/*.so` → `.framework` + `.fwork`; ditto `modules/` and `data/`; bundle test CIFs + the dylib Info template.

**Created/Copied:**
- `swiftui/PyMOLViewer/Resources/dylib-Info-template.plist` — copied from `deps_ios/testbed/iOSTestbed/dylib-Info-template.plist`; consumed by the "Prepare Python Binary Modules" phase.
- `swiftui/PyMOLViewer/Resources/1ubq.cif` — bundled test structure (copy of repo-root `1ubq.cif`) for autoload verification.

**NOT changed:** all of `layer*/`, `layerGraphics/metal/*`, `modules/pymol/metal_pick.py`, `data/shaders_metal/*` — these already work and ship as-is.

---

## Phase 0 — Build the iOS target

### Task 0.1: Ensure `libpymol_core.a` is current for the simulator

**Files:** none (build artifact `build_ios/libpymol_core.a`).

- [ ] **Step 1: Rebuild the static lib from current sources**

Run:
```bash
cd swiftui && ./build_ios.sh simulator 2>&1 | tail -20; cd ..
```
Expected: ends with a successful `pymol_core` build; `build_ios/libpymol_core.a` mtime is now.

- [ ] **Step 2: Confirm arch + key symbols**

Run:
```bash
lipo -info build_ios/libpymol_core.a
nm build_ios/libpymol_core.a 2>/dev/null | grep -E '_PyInit__cmd|_init_cmd|SceneRenderMetal|RendererMetal' | head
```
Expected: `architecture: arm64` (Non-fat) and the four symbols present (`T`/`t`). No commit (untracked artifact).

### Task 0.2: Add the missing `import UIKit`

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/CommandPanel.swift` (top, iOS branch)
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (top, iOS branch)

- [ ] **Step 1: Read the current import blocks** of both files to see the existing `#if os(...)`/`import` structure (do not assume; match what's there).

- [ ] **Step 2: Add `import UIKit` under the iOS branch in each file.** Use the canonical SwiftUI cross-platform pattern at the top of each file:

```swift
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
```
Place it after `import SwiftUI` (and after `import MetalKit` in `MetalViewport.swift`), without disturbing existing imports.

- [ ] **Step 3: Commit**
```bash
git add swiftui/PyMOLViewer/Panels/CommandPanel.swift swiftui/PyMOLViewer/Shared/MetalViewport.swift
git commit -m "fix(ios): import UIKit in CommandPanel and MetalViewport"
```

### Task 0.3: Compile + link the iOS target; fix whatever the build actually reports

**Files:** as needed (driven by compiler output).

- [ ] **Step 1: Regenerate the project**
```bash
cd swiftui && xcodegen generate && cd ..
```
Expected: "Created project at .../PyMOLViewer.xcodeproj".

- [ ] **Step 2: Build (capture errors)** — use the canonical build command above.
Expected initially: it may surface additional Swift/ObjC++ errors beyond the imports.

- [ ] **Step 3: Fix each reported error at its source.** Likely candidates (fix only if the compiler reports them): UIKit-only symbols still under a macOS branch; `Color(nsColor:)`/`Color(uiColor:)` mismatches; `NSEvent`/`UIKeyCommand` guards. Make the minimal edit the compiler demands; re-run Step 2 until it builds.

- [ ] **Step 4: Confirm a clean build + that the core/deps linked**
Expected: `** BUILD SUCCEEDED **`, and `ls -d "$APP"` exists.

- [ ] **Step 5: Commit** any fixes:
```bash
git add -A swiftui/PyMOLViewer
git commit -m "fix(ios): resolve iOS-target compile errors; link clean for simulator"
```

> **Checkpoint 0:** `** BUILD SUCCEEDED **` for `PyMOLViewer_iOS` on `iphonesimulator`. (Launch will still fail until Phase 1 — that's expected.)

---

## Phase 1 — Launch with embedded CPython 3.13

> The adversarial review proved that without ALL of the steps below the app is killed by dyld before `main()` (framework not embedded), or aborts in `Py_InitializeFromConfig` (stdlib not bundled), or fails `import math` (lib-dynload `.so` not repackaged as `.fwork`). Do them together; verify at the end of the phase.

### Task 1.1: Copy the dylib Info-plist template into the app's resources

**Files:**
- Create: `swiftui/PyMOLViewer/Resources/dylib-Info-template.plist`

- [ ] **Step 1: Copy the proven template**
```bash
mkdir -p swiftui/PyMOLViewer/Resources
cp deps_ios/testbed/iOSTestbed/dylib-Info-template.plist swiftui/PyMOLViewer/Resources/dylib-Info-template.plist
```
- [ ] **Step 2: Sanity-check it has the CFBundle keys** the repackage script stamps:
```bash
plutil -p swiftui/PyMOLViewer/Resources/dylib-Info-template.plist | grep -E 'CFBundleExecutable|CFBundleIdentifier|CFBundlePackageType'
```
Expected: those keys exist (values are placeholders, replaced per-module at build time).
- [ ] **Step 3: Commit**
```bash
git add swiftui/PyMOLViewer/Resources/dylib-Info-template.plist
git commit -m "build(ios): add dylib Info template for Python extension repackaging"
```

### Task 1.2: Bundle a test structure for verification

**Files:**
- Create: `swiftui/PyMOLViewer/Resources/1ubq.cif`

- [ ] **Step 1: Copy the repo-root test CIF into resources**
```bash
cp 1ubq.cif swiftui/PyMOLViewer/Resources/1ubq.cif
```
- [ ] **Step 2: Commit**
```bash
git add swiftui/PyMOLViewer/Resources/1ubq.cif
git commit -m "test(ios): bundle 1ubq.cif for autoload verification"
```

### Task 1.3: Restructure `project.yml` — per-platform targets + iOS packaging phases

**Files:**
- Modify: `swiftui/project.yml`

**Why split:** xcodegen 2.45 cannot condition `dependencies`/scripts per-platform inside one multi-platform target. macOS must keep its current behavior (it uses Homebrew Python + CMake bundling); only iOS gets the embed/copy phases. Keep the generated scheme names `PyMOLViewer_iOS` / `PyMOLViewer_macOS` (the existing `xcshareddata/xcschemes` and this plan's commands depend on them).

- [ ] **Step 1: Read the current `swiftui/project.yml`** in full and note: the existing `name:`, `targets:` block, `settings`, `sources`, `configFiles` (it points at `PyMOLBridge.xcconfig`), and the current `PRODUCT_BUNDLE_IDENTIFIER`. Preserve everything macOS already relies on.

- [ ] **Step 2: Replace the single multi-platform target with a shared template + two single-platform targets.** Adapt the block below to the real field values you just read (keep the existing `configFiles`/xcconfig wiring, settings, and Info.plist generation). The macOS target must remain behavior-identical to today.

```yaml
# project.yml — target section (paths are relative to swiftui/)
targetTemplates:
  PyMOLCommon:
    type: application
    configFiles:
      Debug: PyMOLBridge.xcconfig
      Release: PyMOLBridge.xcconfig
    sources:
      - path: PyMOLViewer
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.pymol.viewer
        GENERATE_INFOPLIST_FILE: YES
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: 1
        INFOPLIST_KEY_CFBundleDisplayName: PyMOL

targets:
  # macOS — keep EXACTLY as before (no embed/copy phases). Fill in any
  # platform-specific settings the current macOS target had.
  PyMOLViewer_macOS:
    templates: [PyMOLCommon]
    platform: macOS
    deploymentTarget: "13.0"

  # iOS — adds all runtime packaging.
  PyMOLViewer_iOS:
    templates: [PyMOLCommon]
    platform: iOS
    deploymentTarget: "16.0"
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1,2"
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/Frameworks"
    dependencies:
      - framework: ../deps_ios/Python.xcframework
        embed: true
        codeSign: true
    postCompileScripts:
      - name: "Install Python Standard Library"
        basedOnDependencyAnalysis: false
        script: |
          set -e
          mkdir -p "$CODESIGNING_FOLDER_PATH/python/lib"
          if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
            rsync -au --delete "$PROJECT_DIR/../deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/" "$CODESIGNING_FOLDER_PATH/python/lib/"
          else
            rsync -au --delete "$PROJECT_DIR/../deps_ios/Python.xcframework/ios-arm64/lib/" "$CODESIGNING_FOLDER_PATH/python/lib/"
          fi
    postBuildScripts:
      - name: "Prepare Python Binary Modules"
        basedOnDependencyAnalysis: false
        script: |
          set -e
          install_dylib () {
            INSTALL_BASE=$1; FULL_EXT=$2
            RELATIVE_EXT=${FULL_EXT#$CODESIGNING_FOLDER_PATH/}
            PYTHON_EXT=${RELATIVE_EXT/$INSTALL_BASE/}
            FULL_MODULE_NAME=$(echo $PYTHON_EXT | cut -d "." -f 1 | tr "/" ".")
            FRAMEWORK_BUNDLE_ID=$(echo $PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME | tr "_" "-")
            FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"
            if [ ! -d "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" ]; then
              mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
              cp "$CODESIGNING_FOLDER_PATH/dylib-Info-template.plist" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
              plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
              plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
            fi
            mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
            echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > "${FULL_EXT%.so}.fwork"
            echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"
          }
          PYTHON_VER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib")
          find "$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER/lib-dynload" -name "*.so" | while read FULL_EXT; do
            install_dylib "python/lib/$PYTHON_VER/lib-dynload/" "$FULL_EXT"
          done
          if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
            find "$CODESIGNING_FOLDER_PATH/Frameworks" -name "*.framework" -exec /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags "{}" \;
          fi
      - name: "Bundle PyMOL modules"
        basedOnDependencyAnalysis: false
        script: |
          set -e
          ditto "$SRCROOT/../modules" "$CODESIGNING_FOLDER_PATH/modules"
      - name: "Bundle PyMOL data"
        basedOnDependencyAnalysis: false
        script: |
          set -e
          ditto "$SRCROOT/../data" "$CODESIGNING_FOLDER_PATH/data"
```

Notes baked in from research: the stdlib lives **inside** the xcframework slice (`<slice>/lib/python3.13/`); there is no separate `python-stdlib` dir. `data/` already contains `shaders_metal/`. `modules/` ships no compiled `.so`, so the repackage phase only scans `lib-dynload`. The codesign step is guarded so a simulator build (no signing identity) doesn't fail; on the simulator the `.fwork` layout is still produced because CPython-iOS's loader expects it.

- [ ] **Step 3: Verify `PyMOLBridge.xcconfig` doesn't leak macOS Python into iOS.** The Homebrew/3.14 lines are already `[sdk=macosx*]`-scoped (good). Check `project.yml` for any **unconditioned** `FRAMEWORK_SEARCH_PATHS`/`LIBRARY_SEARCH_PATHS` pointing at Homebrew and, if present, scope them `[sdk=macosx*]` or move them into the macOS target only.
```bash
grep -nE 'FRAMEWORK_SEARCH_PATHS|LIBRARY_SEARCH_PATHS|homebrew|3\.14' swiftui/project.yml
```
- [ ] **Step 4: Regenerate and verify the phases landed on iOS only**
```bash
cd swiftui && xcodegen generate && cd ..
grep -c 'PBXShellScriptBuildPhase' swiftui/PyMOLViewer.xcodeproj/project.pbxproj   # expect >= 4
grep -c 'PBXCopyFilesBuildPhase'   swiftui/PyMOLViewer.xcodeproj/project.pbxproj   # expect >= 1 (Embed)
ls swiftui/PyMOLViewer.xcodeproj/xcshareddata/xcschemes/                            # expect PyMOLViewer_iOS / _macOS
```
- [ ] **Step 5: Commit**
```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj
git commit -m "build(ios): embed Python.xcframework + bundle stdlib/modules/data via BeeWare packaging"
```

### Task 1.4: Rewrite `PyMOLBridge_InitPython` to the modern `PyConfig` flow (Python 3.13)

**Files:**
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm` (the `PyMOLBridge_InitPython` function, ~lines 52–81)

- [ ] **Step 1: Read the current `PyMOLBridge_InitPython`** and the file's existing includes / `extern "C"` decls for `PyInit__cmd` and `init_cmd` (research confirmed they're already declared near the top).

- [ ] **Step 2: Replace the function body** with the PyConfig flow. Set `config.home` to `<resourcePath>/python` (the dir **containing** `lib/python3.13`), register `_cmd` before init, `init_cmd()` after, insert `modules` on `sys.path`, set env, keep the existing PyMOL instance wiring:

```objcpp
void PyMOLBridge_InitPython(PyMOLHandle h, const char *resourcePath)
{
    if (!h || !resourcePath) return;

    // Register the statically-linked _cmd builtin BEFORE init (top-level name only).
    PyImport_AppendInittab("_cmd", PyInit__cmd);

    NSString *resPath     = [NSString stringWithUTF8String:resourcePath];
    NSString *pythonHome  = [resPath stringByAppendingPathComponent:@"python"];          // contains lib/python3.13
    NSString *modulesPath = [resPath stringByAppendingPathComponent:@"modules"];
    NSString *dataPath    = [resPath stringByAppendingPathComponent:@"data"];

    PyConfig config;
    PyConfig_InitPythonConfig(&config);     // site_import on (NOT isolated): PyMOL relies on normal sys.path
    config.isolated = 0;
    config.site_import = 1;
    config.write_bytecode = 0;              // app bundle is read-only / signed
    config.buffered_stdio = 0;
    PyConfig_SetBytesString(&config, &config.program_name, "PyMOL");
    PyConfig_SetBytesString(&config, &config.home, [pythonHome UTF8String]);

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"[PyMOL] Python init failed: %s", status.err_msg ? status.err_msg : "(unknown)");
        return;
    }

    init_cmd();                             // register pymol._cmd in sys.modules

    PyObject *sysPath = PySys_GetObject("path");
    if (sysPath) {
        PyObject *p = PyUnicode_FromString([modulesPath UTF8String]);
        PyList_Insert(sysPath, 0, p);
        Py_DECREF(p);
    }

    setenv("PYMOL_PATH", [resPath UTF8String], 1);
    setenv("PYMOL_DATA", [dataPath UTF8String], 1);

    // Existing PyMOL instance wiring (keep whatever the current code did here):
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    PInit(G, true);
    PyMOL_SetDefaultMouse(INST(h));
    PyMOL_SetPythonInitStage(INST(h), 1);
}
```
If the current code already performs the `PInit`/`SetDefaultMouse`/`SetPythonInitStage` wiring elsewhere (e.g. in `PyMOLBridge_Start`), do NOT duplicate it — keep the single existing call site and only replace the init-up-to-`init_cmd()` portion.

- [ ] **Step 3: Build** (canonical command). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**
```bash
git add swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm
git commit -m "feat(ios): boot embedded CPython 3.13 via PyConfig (home=<res>/python)"
```

### Task 1.5: Launch on the simulator and verify Python boots + `import pymol` works

**Files:** none (verification); fix forward if it fails.

- [ ] **Step 1: Install + launch with console capture** (canonical commands). 

- [ ] **Step 2: Inspect the log** `/tmp/pymol_ios.log` for the failure ladder the adversarial review predicted:
  - dyld error `Library not loaded: @rpath/Python.framework/Python` → embed phase didn't run/copy; revisit Task 1.3.
  - `ModuleNotFoundError: No module named 'encodings'` / `unable to load the file system codec` → stdlib not at `<App>/python/lib/python3.13`; check the rsync phase ran (look at the built app: `find "$APP/python/lib/python3.13" -maxdepth 1 | head`).
  - `ModuleNotFoundError` on `math`/`_socket`/etc. → `.fwork` repackaging didn't run; check `ls "$APP/Frameworks" | grep -E 'math|select'` and `find "$APP/python/lib/python3.13/lib-dynload" -name '*.fwork' | head`.
  - Fatal in `PImportModuleOrFatal('pymol')` / `chempy` → see Step 4.

- [ ] **Step 3: Positive check — Python version via the bridge.** Confirm the app reached PyMOL init: grep the log for PyMOL's banner, or temporarily set `SIMCTL_CHILD_PYMOL_AUTOLOAD=1ubq.cif` and confirm no Python traceback appears. Expected: log shows PyMOL initializing with no Python traceback.

- [ ] **Step 4: Handle `chempy.champ` / numpy if they abort import.** Research found `modules/chempy/champ/` exists but ships no `_champ.so` on iOS, and numpy isn't bundled. If the log shows an import abort from `champ` or `numpy` during `PImportModuleOrFatal`, apply the minimal guard: confirm whether `import pymol` triggers it (`grep -rn "import.*champ\|import numpy" modules/pymol/__init__.py modules/chempy/__init__.py`), and if a top-level import is the culprit, wrap that specific import in a `try/except ImportError` in the offending module (smallest change that lets PyMOL load without the optional dependency). Re-launch and re-check.

- [ ] **Step 5: Commit** any import-guard fix:
```bash
git add -A modules
git commit -m "fix(ios): tolerate missing optional champ/numpy on import"
```

> **Checkpoint 1:** App launches on the simulator (no dyld kill), `Py_InitializeFromConfig` succeeds, and `import pymol` completes with no traceback in `/tmp/pymol_ios.log`. (Viewport is still black — Phase 2.)

---

## Phase 2 — Render a structure via Metal

### Task 2.1: Declare the new render bridge functions

**Files:**
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h` (after the existing `PyMOLBridge_RenderMetal` decl, ~line 43)

- [ ] **Step 1: Add the declarations** (opaque `void*` so the C header needs no Metal import):
```c
// --- Metal renderer construction + per-frame handoff (iOS) ---
void PyMOLBridge_SetupMetalRenderer(PyMOLHandle instance, void *mtkView);
void PyMOLBridge_RenderMetalFrame(PyMOLHandle instance, void *drawable, void *passDescriptor, int width, int height);
```
- [ ] **Step 2: Commit**
```bash
git add swiftui/PyMOLViewer/Bridge/PyMOLBridge.h
git commit -m "feat(ios): declare Metal renderer setup + frame bridge"
```

### Task 2.2: Implement renderer construction + per-frame handoff

**Files:**
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm` (imports at top; two new functions)

- [ ] **Step 1: Add imports/includes** near the top of the file (after the existing Foundation import):
```objcpp
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include "RendererMetal.h"
#include "SceneRender.h"            // declares void SceneRenderMetal(PyMOLGlobals*)
// Immediate-mode batch hook used by SceneRenderMetal (defined in core):
namespace pymol { class Renderer; }
extern void ImmBatch_SetActiveRenderer(pymol::Renderer* r);
```
If `RendererMetal.h`/`SceneRender.h` don't resolve, add their dirs to `PYMOL_INCLUDE_FLAGS_COMMON` in `PyMOLBridge.xcconfig` (it already lists `layerGraphics/metal`).

- [ ] **Step 2: Implement `PyMOLBridge_SetupMetalRenderer`** (idempotent; mirrors `main_appkit.mm:686–691`):
```objcpp
void PyMOLBridge_SetupMetalRenderer(PyMOLHandle h, void *mtkViewPtr)
{
    if (!h || !mtkViewPtr) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G || G->Renderer) return;                       // idempotent: build once
    MTKView *v = (__bridge MTKView *)mtkViewPtr;
    id<MTLDevice> device = v.device ?: MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue]; // MTKView has no queue; renderer owns this
    G->HaveGUI = true;                                    // main_appkit.mm:688
    G->Renderer = new pymol::RendererMetal(device, queue);
}
```

- [ ] **Step 3: Implement `PyMOLBridge_RenderMetalFrame`** (mirrors `drawInMTKView` `main_appkit.mm:809–868`; ordering is load-bearing):
```objcpp
void PyMOLBridge_RenderMetalFrame(PyMOLHandle h, void *drawablePtr, void *passDescPtr, int width, int height)
{
    if (!h) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    auto *renderer = static_cast<pymol::RendererMetal *>(G->Renderer);
    if (!renderer) return;
    id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)drawablePtr;
    MTLRenderPassDescriptor *passDesc = (__bridge MTLRenderPassDescriptor *)passDescPtr;
    if (!drawable || !passDesc) return;

    renderer->setDrawable(drawable, passDesc);
    renderer->viewport(0, 0, width, height);
    renderer->beginFrame();
    ImmBatch_SetActiveRenderer(renderer);
    PyMOL_PushValidContext(INST(h));
    SceneRenderMetal(G);
    PyMOL_PopValidContext(INST(h));
    ImmBatch_SetActiveRenderer(nullptr);
    renderer->endFrame();
}
```
Do NOT call `PyMOL_Idle` here (Swift `engine.idle()` already runs before this; double-idling is a known footgun).

- [ ] **Step 4: Build.** Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit**
```bash
git add swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm
git commit -m "feat(ios): construct RendererMetal and hand off drawable per frame"
```

### Task 2.3: Swift wrappers in `PyMOLEngine`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (near the existing render methods, ~lines 87–100)

- [ ] **Step 1: Add the two methods**:
```swift
func setupMetalRenderer(view: MTKView) {
    guard let inst = instance else { return }
    PyMOLBridge_SetupMetalRenderer(inst, Unmanaged.passUnretained(view).toOpaque())
}

func renderMetalFrame(drawable: CAMetalDrawable, passDescriptor: MTLRenderPassDescriptor, width: Int, height: Int) {
    guard let inst = instance else { return }
    PyMOLBridge_RenderMetalFrame(inst,
        Unmanaged.passUnretained(drawable).toOpaque(),
        Unmanaged.passUnretained(passDescriptor).toOpaque(),
        Int32(width), Int32(height))
}
```
(Use `passUnretained` — the frame owns these objects for the call's duration; `endFrame` releases the renderer's refs. Retaining would leak per frame.) If `instance`/the property name differs in the file, match the existing convention.

- [ ] **Step 2: Build; commit**
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(ios): PyMOLEngine wrappers for Metal renderer setup + frame"
```

### Task 2.4: Rewrite `MetalViewport.draw(in:)`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (`Coordinator.draw(in:)`, ~lines 129–143)

- [ ] **Step 1: Read the current `draw(in:)`** and the `Coordinator`'s reference to the view/engine (note how `engine` and the `MTKView` are accessed; `isReady` may be named differently — match it).

- [ ] **Step 2: Replace `draw(in:)`** with construct-then-handoff:
```swift
func draw(in view: MTKView) {
    guard let engine = engine, engine.isReady else { return }
    engine.setupMetalRenderer(view: view)        // idempotent; builds RendererMetal on first frame
    engine.idle()
    guard let drawable = view.currentDrawable,
          let passDesc = view.currentRenderPassDescriptor else { return }
    let size = view.drawableSize
    engine.renderMetalFrame(drawable: drawable, passDescriptor: passDesc,
                            width: Int(size.width), height: Int(size.height))
}
```
Remove the now-dead `PyMOLBridge_GetRenderer` fetch and any separate `renderMetal()`/`pushValidContext()`/`popValidContext()` calls in this path (the bridge does push/pop internally now). If `engine.isReady` doesn't exist, gate on `engine.instance != nil` plus the existing readiness flag the file uses.

- [ ] **Step 3: Build; commit**
```bash
git add swiftui/PyMOLViewer/Shared/MetalViewport.swift
git commit -m "feat(ios): wire MetalViewport draw loop to construct + drive RendererMetal"
```

### Task 2.5: Verify a cartoon renders

**Files:** none (verification); contingency below.

- [ ] **Step 1: Launch with autoload** (add the autoload hook first if not present — see Task 2.6) and screenshot:
```bash
xcrun simctl install "$SIM" "$APP"
SIMCTL_CHILD_PYMOL_AUTOLOAD=1ubq.cif xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" 2>&1 | tee /tmp/pymol_ios.log &
sleep 8
xcrun simctl io "$SIM" screenshot /tmp/pymol_cartoon.png
```
- [ ] **Step 2: Inspect the screenshot** `/tmp/pymol_cartoon.png`. Expected: viewport shows PyMOL's background and a cartoon of ubiquitin (not a black/empty view).
- [ ] **Step 3: If the view is blank, check shader/pipeline init in the log** for `MetalShaderMgr` messages. `isRenderReady()` needs `_batchPipeline`, built from the shader library; on iOS `MetalShaderMgr` should runtime-compile from the bundled `data/shaders_metal/`. Look for compile errors.
- [ ] **Step 4 (contingency): precompiled metallib.** If runtime compilation fails on iOS, precompile and bundle a metallib instead:
```bash
python3 scripts/compile_metal_shaders.py --sdk iphonesimulator --output swiftui/PyMOLViewer/Resources/pymol.metallib
```
then add `pymol.metallib` as a bundled resource (a `ditto`/resource entry in `project.yml`) so `MetalShaderMgr::loadMetallibFromBundle` finds it. Re-launch and re-screenshot. Commit the metallib + project change if used.

> **Checkpoint 2:** `/tmp/pymol_cartoon.png` shows a rendered ubiquitin cartoon on the simulator.

### Task 2.6: (Prereq for 2.5) env-gated autoload hook

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`

- [ ] **Step 1: After PyMOL has started, run the autoload command if the env var is set.** In the engine's post-start path (right after `PyMOLBridge_Start`):
```swift
if let f = ProcessInfo.processInfo.environment["PYMOL_AUTOLOAD"] {
    // f is a bundled resource filename, e.g. "1ubq.cif"
    if let path = Bundle.main.path(forResource: (f as NSString).deletingPathExtension,
                                   ofType: (f as NSString).pathExtension) {
        runCommand("load \(path); hide everything; show cartoon; orient")
    }
}
```
Use the existing `runCommand` wrapper. This is harmless when the env var is unset.

- [ ] **Step 2: Build; commit**
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "test(ios): env-gated autoload hook for screenshot verification"
```
(Implement 2.6 before running 2.5.)

---

## Phase 3 — Touch interaction + atom picking

### Task 3.1: Verify rotate / zoom already work

**Files:** none (verification).

- [ ] **Step 1: With a structure autoloaded, confirm the existing gesture path drives PyMOL.** Read `MetalViewport.swift` `handlePan`/pinch handlers and confirm they call `engine`'s button/drag wrappers (which call `PyMOLBridge_Button`/`PyMOLBridge_Drag` → `PyMOL_Button`/`PyMOL_Drag`). These use PyMOL's normal trackball and are backend-agnostic.
- [ ] **Step 2 (manual):** In the booted Simulator, drag in the viewport (rotate) and pinch (zoom) on the loaded cartoon; confirm it responds and stays stable. Screenshot before/after for the record. (Automated touch synthesis is out of scope; this is a human check.)

### Task 3.2: Add the pick bridge (`metal_pick.pick_at` under PBlock/PUnblock)

**Files:**
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h` (decl)
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm` (impl)

- [ ] **Step 1: Declare** in `PyMOLBridge.h`:
```c
// Tap-to-select: NDC coords in [-1,1], aspect = width/height.
void PyMOLBridge_Pick(PyMOLHandle instance, float ndcX, float ndcY, float aspect);
```
- [ ] **Step 2: Implement** in `PyMOLBridge.mm` (mirrors `main_appkit.mm:948–968`; **must** use `PBlock`/`PUnblock`, NOT `PyGILState_Ensure`, and NOT `PyMOLBridge_RunCommand` which uses `PyGILState_Ensure` and would risk a GIL deadlock):
```objcpp
void PyMOLBridge_Pick(PyMOLHandle h, float ndcX, float ndcY, float aspect)
{
    if (!h) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    char script[256];
    snprintf(script, sizeof(script),
             "from pymol.metal_pick import pick_at; pick_at(%f, %f, %f)",
             ndcX, ndcY, aspect);
    PBlock(G);
    PyRun_SimpleString(script);
    PUnblock(G);
}
```
`P.h` (declaring `PBlock`/`PUnblock`) is already included by the bridge; confirm or add `#include "P.h"`.

- [ ] **Step 3: Build; commit**
```bash
git add swiftui/PyMOLViewer/Bridge/PyMOLBridge.h swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm
git commit -m "feat(ios): PyMOLBridge_Pick via metal_pick.pick_at under PBlock/PUnblock"
```

### Task 3.3: Swift wrapper for pick

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`

- [ ] **Step 1: Add**:
```swift
func pick(ndcX: Float, ndcY: Float, aspect: Float) {
    guard let inst = instance else { return }
    PyMOLBridge_Pick(inst, ndcX, ndcY, aspect)
}
```
- [ ] **Step 2: Build; commit**
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(ios): PyMOLEngine.pick wrapper"
```

### Task 3.4: Map tap → pick (point-space NDC, Y-flipped)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (`handleTap`, ~lines 242–249)

- [ ] **Step 1: Replace the two `button(LEFT, DOWN/UP)` calls in `handleTap`** (that path does NOT select on Metal) with NDC computation + `engine.pick`. Use **point-space** (`view.bounds`, not backing pixels) and **flip Y** (UIKit top-left vs PyMOL bottom-left):
```swift
@objc func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let engine = engine, let view = gesture.view else { return }
    let p = gesture.location(in: view)
    let w = view.bounds.width, h = view.bounds.height
    guard w > 0, h > 0 else { return }
    let ndcX = Float(p.x / w) * 2 - 1
    let ndcY = 1 - Float(p.y / h) * 2          // Y-flip for UIKit top-left origin
    let aspect = Float(w / h)
    engine.pick(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
}
```
Leave `handlePan`/pinch unchanged (rotation/zoom go through the standard `PyMOL_Drag` path and already work). Do NOT use the existing `pymolPoint()` helper here — it multiplies by `contentScaleFactor` for pixel-space button events and is the wrong space for pick NDC.

- [ ] **Step 2: Build; commit**
```bash
git add swiftui/PyMOLViewer/Shared/MetalViewport.swift
git commit -m "feat(ios): tap-to-select via metal_pick (point-space NDC, Y-flipped)"
```

### Task 3.5: Verify picking end-to-end

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (add the autopick hook for automated verification)

- [ ] **Step 1: Add an env-gated autopick hook** (after autoload), logging the selection size so picking is verifiable without synthesizing a touch:
```swift
if let s = ProcessInfo.processInfo.environment["PYMOL_AUTOPICK"] {
    let parts = s.split(separator: ",").compactMap { Float($0) }
    if parts.count == 2 {
        pick(ndcX: parts[0], ndcY: parts[1], aspect: 1.0)
        runCommand("python print('AUTOPICK_COUNT', cmd.count_atoms('sele')) python end")
    }
}
```
(Use the file's actual multi-line python invocation convention if `python ... python end` differs; the goal is to print `cmd.count_atoms('sele')`.)

- [ ] **Step 2: Build, then launch with autoload + a center pick** and read the log:
```bash
cd swiftui && xcodebuild ... build && cd ..   # canonical build
xcrun simctl install "$SIM" "$APP"
SIMCTL_CHILD_PYMOL_AUTOLOAD=1ubq.cif SIMCTL_CHILD_PYMOL_AUTOPICK=0,0 \
  xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" 2>&1 | tee /tmp/pymol_ios.log &
sleep 8
xcrun simctl io "$SIM" screenshot /tmp/pymol_pick.png
grep AUTOPICK_COUNT /tmp/pymol_ios.log
```
Expected: `AUTOPICK_COUNT <n>` with `n > 0` (a center pick on an oriented, fully-visible ubiquitin hits an atom), and `/tmp/pymol_pick.png` shows the pink selection indicator.

- [ ] **Step 3 (manual):** Tap an atom in the booted Simulator; confirm a pink selection indicator appears at the tapped atom (validates the Y-flip/point-space mapping). If the selection appears vertically mirrored, the Y-flip sign is wrong — flip it.

- [ ] **Step 4: Commit** the autopick hook:
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "test(ios): env-gated autopick hook + selection-count log"
```

> **Checkpoint 3 (MVP complete):** On the simulator — app launches, `1ubq.cif` renders as a cartoon, drag rotates / pinch zooms, and tapping an atom selects it (pink indicator + non-zero `sele`).

### Task 3.6 (optional polish): two-finger rotate

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (`handleRotation`, ~lines 280–283)

- [ ] **Step 1:** Implement the empty `handleRotation` to map a two-finger twist to a z-rotation via `runCommand("turn z, \(degrees)")` using the gesture's rotation delta. Build; manual-verify; commit. Skip if time-constrained — not required for the MVP checkpoint.

---

## Final acceptance

- [ ] Run the full smoke sequence and archive evidence:
```bash
xcrun simctl install "$SIM" "$APP"
SIMCTL_CHILD_PYMOL_AUTOLOAD=1ubq.cif SIMCTL_CHILD_PYMOL_AUTOPICK=0,0 \
  xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" 2>&1 | tee /tmp/pymol_ios.log &
sleep 8
xcrun simctl io "$SIM" screenshot /tmp/pymol_mvp.png
grep -E 'AUTOPICK_COUNT|Traceback|error' /tmp/pymol_ios.log
```
Expected: cartoon visible, `AUTOPICK_COUNT > 0`, no Python traceback.
- [ ] Confirm all four phase checkpoints are green; note any deferred items (device build, AI chat, sequence panel, numpy) as follow-ups.

---

## Self-review (against the spec)

**Spec coverage:**
- DoD #1 (builds/links for iphonesimulator) → Phase 0. ✓
- DoD #2 (launches, command returns feedback) → Phase 1 (Checkpoint 1). ✓
- DoD #3 (cartoon renders via Metal) → Phase 2 (Checkpoint 2). ✓
- DoD #4 (drag/pinch/pan) → Task 3.1. ✓
- DoD #5 (tap-to-select) → Tasks 3.2–3.5 (Checkpoint 3). ✓
- Spec §5 decisions: runtime-compiled shaders → Task 2.5 (+ metallib contingency); PyConfig boot mirroring main_appkit → Task 1.4; project.yml-driven phases → Task 1.3. ✓
- Spec §2 `isPicking` tension → resolved: picking is CPU-side (`metal_pick`), so Task 3.2 uses it instead of the GL color-pick path. ✓

**Placeholder scan:** No "TBD"/"handle errors"/"similar to". The only env-var values (`PYMOL_AUTOLOAD`/`PYMOL_AUTOPICK`) are defined where introduced. Contingencies (champ/numpy guard, metallib precompile) have concrete commands. ✓

**Type/name consistency:** New symbols are used consistently: `PyMOLBridge_SetupMetalRenderer`, `PyMOLBridge_RenderMetalFrame`, `PyMOLBridge_Pick` (C) ↔ `setupMetalRenderer(view:)`, `renderMetalFrame(drawable:passDescriptor:width:height:)`, `pick(ndcX:ndcY:aspect:)` (Swift). Bridge functions take `void*` for Metal objects; Swift passes `Unmanaged.passUnretained(_).toOpaque()`. ✓

**Known assumptions to confirm at execution (flagged inline, not placeholders):** exact current field names in `PyMOLEngine`/`MetalViewport` (`instance`, `isReady`, `runCommand`), and whether `PInit` wiring lives in `InitPython` vs `Start` — each task says to match the existing code.
