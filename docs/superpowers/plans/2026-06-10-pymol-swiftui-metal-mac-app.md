# SwiftUI + Metal PyMOL — Self-Contained Native Mac App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `PyMOLViewer.app` as a self-contained, ad-hoc-signed native macOS app — the SwiftUI + Metal PyMOL running natively on Mac (same codebase as the iPad app), with an embedded relocatable Python (no Homebrew), feature parity with the AppKit app minus chat.

**Architecture:** Mirror the iPad build on macOS. Build the macOS core as a **`_PYMOL_NO_OPENGL` + Metal** archive (no OpenGL/GLEW) linked against **`python-build-standalone` CPython 3.13** — so the *already-shared* `PyMOLBridge.mm` (which assumes `config.home=<res>/python` with `lib/python3.13`) works unchanged. Bundle Python + `modules/` + `data/` + `pymol.metallib` into `Contents/Resources`, then inside-out ad-hoc-sign with a `disable-library-validation` entitlement.

**Tech Stack:** Swift/SwiftUI, ObjC++ bridge, Metal/MetalKit, CMake-built `libpymol_core.a` (macOS arm64, NO_OPENGL+Metal), `python-build-standalone` 3.13.13, xcodegen 2.45, Xcode 26.4, `codesign`.

**Reference spec:** `docs/superpowers/specs/2026-06-10-pymol-swiftui-metal-mac-app-design.md`

---

## Why this differs slightly from the spec's phase order

Grounding research found: (1) the macOS core that `-lpymol_core` currently resolves to (`build_appkit/libpymol_core.a`) is a NO_OPENGL build linking Homebrew **3.14**, while the shared bridge hardcodes the **3.13** `<res>/python` layout — so a "dev run with Homebrew" fights the bridge and is throwaway; (2) the SwiftUI app uses the **Metal** path (not OpenGL), so a NO_OPENGL+Metal core (like iOS) is *cleaner* and drops the GLEW/OpenGL Homebrew deps. So we go **standalone-3.13 from the start** and unify the macOS build with iOS. (The adversarial "willWork:false" was largely about the *AppKit* app's PyObjC/numpy/3.14 startup — not this SwiftUI target, which needs only stdlib + `pymol`, proven on iOS.)

## Verification model

macOS app-integration; verify functionally (build → launch the binary with env affordances → screenshot). The iPad MVP added env-gated affordances in `PyMOLEngine.swift` (`PYMOL_AUTOLOAD`, `PYMOL_AUTOPICK`, `PYMOL_AUTOTURN`) that work cross-platform — reuse them.

**Canonical commands:**
```bash
REPO=/Users/jcastellanos/repos/pymol-open-source
APP="$REPO/swiftui/build_xcode/Build/Products/Debug/PyMOLViewer.app"
BIN="$APP/Contents/MacOS/PyMOLViewer"

# Build the macOS app
cd "$REPO/swiftui" && xcodegen generate
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./build_xcode build 2>&1 | tail -40

# Launch the binary directly with env affordances (so we can pass PYMOL_AUTOLOAD;
# `open` doesn't forward env easily), capture stdout, screenshot the window.
PYMOL_AUTOLOAD=1ubq.cif "$BIN" >/tmp/pymol_mac.log 2>&1 &
PID=$!; sleep 6
screencapture -o -x /tmp/pymol_mac.png   # full screen; the app window is visible
kill $PID 2>/dev/null
```
Note: `1ubq.cif` is already bundled (the iOS Resources copy); on macOS it lands in `Contents/Resources` and `Bundle.main.path(forResource:"1ubq",ofType:"cif")` resolves it.

## File structure (what changes)

**Created:**
- `deps_macos/python-standalone/python/` — extracted `python-build-standalone` 3.13.13 (gitignored; a fetch script records how to obtain it).
- `swiftui/build_macos.sh` — builds the macOS NO_OPENGL+Metal core against the standalone Python (analog of `build_ios.sh`).
- `swiftui/PyMOLViewer/Resources/PyMOLViewer.entitlements` — `disable-library-validation` (+ jit) for ad-hoc hardened-runtime signing.
- `scripts/fetch_macos_python.sh` — downloads + verifies + extracts the standalone Python into `deps_macos/`.

**Modified:**
- `appkit/CMakeLists.txt` — add `PYMOL_METAL_ONLY` option (NO_OPENGL+Metal+stubs source selection on a native build; link a caller-provided Python).
- `layer5/main_ios.cpp` — broaden its `#ifdef _PYMOL_IOS` guard so the `Main*` stubs also compile for the macOS metal-only core.
- `swiftui/PyMOLBridge.xcconfig` — repoint `[sdk=macosx*]` Python/lib/link flags from Homebrew 3.14 to the standalone 3.13; drop `-lxml2 -framework OpenGL -lGLEW`; add the embedded-Python rpath.
- `swiftui/project.yml` — add macOS-guarded build phases (bundle Python/modules/data/metallib into `Contents/Resources`; inside-out ad-hoc sign); set `CODE_SIGN_ENTITLEMENTS` + hardened runtime for the macOS target.
- `.gitignore` — ignore `deps_macos/` and `build_macos*/`.

**NOT changed:** `PyMOLBridge.mm`, `PyMOLEngine.swift`, `MetalViewport.swift`, the panels, the Metal renderer — all shared and already correct (the macOS `NSViewRepresentable` + `NSEvent` paths exist; `Bundle.main.resourcePath` yields `Contents/Resources` on macOS so `config.home=<res>/python` resolves).

---

## Phase A — macOS Metal-only core against embedded Python 3.13

### Task A1: Fetch python-build-standalone 3.13.13

**Files:** Create `scripts/fetch_macos_python.sh`; Modify `.gitignore`.

- [ ] **Step 1: Write the fetch script**
```bash
#!/bin/bash
# scripts/fetch_macos_python.sh — download relocatable CPython 3.13 for embedding.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/deps_macos/python-standalone"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260602/cpython-3.13.13+20260602-aarch64-apple-darwin-install_only.tar.gz"
mkdir -p "$DEST"
cd "$DEST"
curl -L -o py.tar.gz "$URL"
tar -xzf py.tar.gz            # -> ./python/{bin,include,lib,...}
test -f python/lib/libpython3.13.dylib
test -d python/lib/python3.13
echo "OK: $DEST/python"
```
- [ ] **Step 2: Add `.gitignore` entries** (append):
```
deps_macos/
build_macos/
build_macos_swiftui/
```
- [ ] **Step 3: Run it + verify relocatability**
```bash
bash scripts/fetch_macos_python.sh
./deps_macos/python-standalone/python/bin/python3.13 -c 'import sys,sysconfig;print(sys.prefix);print(sysconfig.get_path("stdlib"))'
lipo -archs deps_macos/python-standalone/python/lib/libpython3.13.dylib
otool -D deps_macos/python-standalone/python/lib/libpython3.13.dylib
```
Expected: prefix = `.../python`, stdlib = `.../python/lib/python3.13`; arch `arm64`; install_name `@rpath/libpython3.13.dylib`.
- [ ] **Step 4: Commit** the scripts (not the binary):
```bash
git add scripts/fetch_macos_python.sh .gitignore
git commit -m "build(macos): fetch script for relocatable python-build-standalone 3.13"
```

### Task A2: Add a `PYMOL_METAL_ONLY` CMake config (NO_OPENGL + Metal, native macOS)

**Files:** Modify `appkit/CMakeLists.txt`; Modify `layer5/main_ios.cpp`.

- [ ] **Step 1: Read** `appkit/CMakeLists.txt` around the `PYMOL_IOS` option, the GL-vs-stub source selection (`~:120-134`), the defines block (`~:198-202`), and the Python/GLEW/libxml find logic. Identify exactly what the `PYMOL_IOS=ON` branch does (defines `_PYMOL_NO_OPENGL`, swaps `gl/*.cpp` → `GLVertexBuffer_stubs.cpp`, compiles `main_ios.cpp`, excludes `main.cpp`/`main_appkit.mm`, always compiles `RendererMetal.mm`/`MetalShaderMgr.mm`).

- [ ] **Step 2: Add the option + reuse the NO_OPENGL source selection on native builds.** Introduce `option(PYMOL_METAL_ONLY "Metal-only (no OpenGL) native build for the SwiftUI app" OFF)`. Wherever the file currently tests `if(PYMOL_IOS)` for **source selection and `_PYMOL_NO_OPENGL`** (NOT the iOS toolchain/Python parts), change the guard to `if(PYMOL_IOS OR PYMOL_METAL_ONLY)`. Concretely:
  - GL sources: `if(PYMOL_IOS OR PYMOL_METAL_ONLY)` → add `GLVertexBuffer_stubs.cpp`, else glob `gl/*.cpp`.
  - layer5 filter: exclude `main.cpp` and `main_appkit` (keep `main_ios.cpp`) when `PYMOL_IOS OR PYMOL_METAL_ONLY`.
  - Defines: `target_compile_definitions(... _PYMOL_NO_OPENGL)` when `PYMOL_IOS OR PYMOL_METAL_ONLY`; add `_PYMOL_IOS` ONLY when `PYMOL_IOS`, and add `_PYMOL_METAL_ONLY` when `PYMOL_METAL_ONLY`.
  - Python/GLEW/libxml: when `PYMOL_METAL_ONLY`, do NOT `find_package(GLEW)`/OpenGL/libxml; take Python include + lib from cache vars `PYMOL_PYTHON_INCLUDE_DIR` and `PYMOL_PYTHON_LIBRARY` (set by `build_macos.sh`).

- [ ] **Step 3: Broaden the `main_ios.cpp` guard** so its `Main*` stubs compile for the metal-only macOS core (the SwiftUI macOS core has no `main_appkit.mm` to provide them):
```cpp
// layer5/main_ios.cpp
#if defined(_PYMOL_IOS) || defined(_PYMOL_METAL_ONLY)
```
(replace the existing `#ifdef _PYMOL_IOS` at the top; keep the matching `#endif`).

- [ ] **Step 4: Commit**
```bash
git add appkit/CMakeLists.txt layer5/main_ios.cpp
git commit -m "build(macos): PYMOL_METAL_ONLY config (NO_OPENGL+Metal native core)"
```

### Task A3: Build the macOS Metal-only core against standalone Python

**Files:** Create `swiftui/build_macos.sh`.

- [ ] **Step 1: Write the build script**
```bash
#!/bin/bash
# swiftui/build_macos.sh — build libpymol_core.a for macOS (arm64, NO_OPENGL+Metal)
# linked against the embedded python-build-standalone 3.13.
set -euo pipefail
PYMOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$PYMOL_ROOT/deps_macos/python-standalone/python"
BUILD_DIR="$PYMOL_ROOT/build_macos_swiftui"
NCPU=$(sysctl -n hw.ncpu)
test -d "$PY" || { echo "run scripts/fetch_macos_python.sh first"; exit 1; }
mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
cmake "$PYMOL_ROOT/appkit" \
  -DPYMOL_METAL_ONLY=ON -DPYMOL_IOS=OFF -DPYMOL_LIBXML=OFF -DPYMOL_VMD_PLUGINS=OFF -DPYMOL_MSGPACKC=OFF \
  -DPYMOL_PYTHON_INCLUDE_DIR="$PY/include/python3.13" \
  -DPYMOL_PYTHON_LIBRARY="$PY/lib/libpython3.13.dylib" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build . --target pymol_core -j"$NCPU"
echo "=== $BUILD_DIR/libpymol_core.a ==="
lipo -archs "$BUILD_DIR/libpymol_core.a"
```
- [ ] **Step 2: Build it**
```bash
bash swiftui/build_macos.sh 2>&1 | tail -30
```
Expected: ends with `arm64`; resolve any compile errors (the metal-only path is new on native macOS — expect a few; fix at the source the compiler reports).
- [ ] **Step 3: Verify the core profile** (macOS arm64, NO_OPENGL, Metal, _cmd):
```bash
nm build_macos_swiftui/libpymol_core.a 2>/dev/null | grep -cE 'U _gl[A-Z]'   # expect 0
nm build_macos_swiftui/libpymol_core.a 2>/dev/null | grep -E 'RendererMetal|_PyInit__cmd|MainAsPyList' | head
```
Expected: 0 undefined GL symbols; `RendererMetal`, `_PyInit__cmd`, `MainAsPyList` present.
- [ ] **Step 4: Commit**
```bash
git add swiftui/build_macos.sh
git commit -m "build(macos): build_macos.sh -> NO_OPENGL+Metal core vs standalone Python 3.13"
```

> **Checkpoint A:** `build_macos_swiftui/libpymol_core.a` is a macOS arm64, NO_OPENGL+Metal core linked against standalone Python 3.13, exporting `_PyInit__cmd` + `MainAsPyList` + the Metal renderer, with zero undefined GL symbols.

---

## Phase B — App builds, bundles, launches, renders

### Task B1: Repoint the macOS xcconfig at the standalone core + Python

**Files:** Modify `swiftui/PyMOLBridge.xcconfig`.

- [ ] **Step 1: Read** the `[sdk=macosx*]` lines (library search paths line ~14, python headers line ~22, `PYMOL_PLATFORM_LDFLAGS[sdk=macosx*]` line ~58, generated-shader dir).
- [ ] **Step 2: Edit the macOS variants** to use the standalone core + Python and drop OpenGL/GLEW/xml2:
```
PYMOL_BUILD_MACOS = $(SRCROOT)/../build_macos_swiftui
LIBRARY_SEARCH_PATHS[sdk=macosx*] = $(PYMOL_BUILD_MACOS) $(SRCROOT)/../deps_macos/python-standalone/python/lib $(SRCROOT)/../deps_ios/install/lib
PYMOL_PYTHON_INC[sdk=macosx*] = -I$(SRCROOT)/../deps_macos/python-standalone/python/include/python3.13
PYMOL_GENERATED_FLAGS[sdk=macosx*] = -I$(PYMOL_BUILD_MACOS)/generated
PYMOL_PLATFORM_LDFLAGS[sdk=macosx*] = -lfreetype -lpng16 -lz -lpython3.13
LD_RUNPATH_SEARCH_PATHS[sdk=macosx*] = $(inherited) @executable_path/../Resources/python/lib
```
(freetype/png: if the macOS core needs them, ensure they resolve — Homebrew `/opt/homebrew/lib` may still be a build-time search path, but for a self-contained app prefer the iOS-cross-built or system copies; confirm during build and add `-L/opt/homebrew/lib` only as a build-time fallback, NOT a runtime dep. If freetype/png end up as Homebrew runtime deps, add them to the embed+sign list in Task D1.)
- [ ] **Step 3: Commit**
```bash
git add swiftui/PyMOLBridge.xcconfig
git commit -m "build(macos): link the standalone core + python3.13; drop OpenGL/GLEW/xml2"
```

### Task B2: Add macOS-guarded bundling build phases

**Files:** Modify `swiftui/project.yml`.

- [ ] **Step 1: Read** the existing iOS-guarded `postBuildScripts` (the `case "$PLATFORM_NAME" in iphone*)` phases) as the pattern.
- [ ] **Step 2: Append macOS-guarded phases** to `targets.PyMOLViewer.postBuildScripts` (macOS bundle layout: payload under `Contents/Resources`, not the bundle root):
```yaml
      - name: "macOS: Bundle Python + modules + data"
        basedOnDependencyAnalysis: false
        script: |
          case "$PLATFORM_NAME" in macosx*) ;; *) exit 0 ;; esac
          set -e
          RES="$CODESIGNING_FOLDER_PATH/Contents/Resources"
          mkdir -p "$RES"
          rsync -au --delete "$SRCROOT/../deps_macos/python-standalone/python/" "$RES/python/"
          ditto "$SRCROOT/../modules" "$RES/modules"
          ditto "$SRCROOT/../data" "$RES/data"
      - name: "macOS: Build + bundle pymol.metallib"
        basedOnDependencyAnalysis: false
        script: |
          case "$PLATFORM_NAME" in macosx*) ;; *) exit 0 ;; esac
          set -e
          RES="$CODESIGNING_FOLDER_PATH/Contents/Resources"
          /usr/bin/python3 "$SRCROOT/../scripts/compile_metal_shaders.py" --sdk macosx --output "/tmp/pymol.metallib" || true
          [ -f /tmp/pymol.metallib ] && cp /tmp/pymol.metallib "$RES/pymol.metallib" || echo "metallib skipped (runtime-compile fallback)"
```
(Trim the staged Python to shrink the bundle — `bin/`, `include/`, `lib/python3.13/test`, `__pycache__` — as an optional later step; keep `lib/libpython3.13.dylib` + `lib/python3.13/` + `lib-dynload/`.)
- [ ] **Step 3: Regenerate + build + verify the payload**
```bash
cd swiftui && xcodegen generate && cd ..
# (canonical build)
ls "$APP/Contents/Resources/python/lib/python3.13/encodings" >/dev/null && echo "stdlib OK"
ls -d "$APP/Contents/Resources/modules/pymol" "$APP/Contents/Resources/data/shaders_metal"
```
Expected: stdlib, `modules/pymol`, `data/shaders_metal` present in `Contents/Resources`.
- [ ] **Step 4: Commit**
```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj
git commit -m "build(macos): bundle Python/modules/data/metallib into Contents/Resources"
```

### Task B3: Launch + render

**Files:** none (verification; fix-forward).

- [ ] **Step 1: Build, then launch the binary with autoload** (canonical commands with `PYMOL_AUTOLOAD=1ubq.cif`).
- [ ] **Step 2: Inspect** `/tmp/pymol_mac.log` for dyld/Python errors. Likely first-launch issues + fixes:
  - `Library not loaded: @rpath/libpython3.13.dylib` → the `LD_RUNPATH_SEARCH_PATHS` rpath (B1) isn't reaching the embedded lib; confirm `otool -l "$BIN" | grep -A2 LC_RPATH` includes `@executable_path/../Resources/python/lib`.
  - `No module named 'encodings'` → `config.home` not resolving to `Contents/Resources/python`; confirm the rsync put `python/lib/python3.13` there and `Bundle.main.resourcePath` is `Contents/Resources`.
  - `ModuleNotFoundError` on a `pymol`/`chempy` import (e.g. `chempy.champ`/numpy) → same optional-import guard the iOS build used; apply it (mirror the iOS fix).
- [ ] **Step 3: Screenshot** `/tmp/pymol_mac.png` — expect the ubiquitin cartoon rendered via Metal in the app window.
- [ ] **Step 4: Confirm no Homebrew/system-Python runtime dep**
```bash
otool -L "$BIN" | grep -iE 'python|/opt/homebrew|/usr/local' || echo "no external python linkage (good)"
otool -L "$BIN" | grep -i python   # expect @rpath/libpython3.13.dylib only
```

> **Checkpoint B:** the native macOS `PyMOLViewer.app` launches, renders the `1ubq` cartoon via Metal, and links its embedded `@rpath/libpython3.13.dylib` with no Homebrew/system-Python dependency.

---

## Phase C — Feature parity (panels + input, minus chat)

### Task C1: Verify panels + mouse/keyboard on macOS

**Files:** fix-forward only (the panels/`MetalViewport` macOS paths are shared and already present).

- [ ] **Step 1: Drive each surface and confirm** (launch without autoload, interact, screenshot):
  - Command panel: type `fab AG, pep; show cartoon; orient` → renders.
  - Objects panel: shows the loaded object; A/S/H toggles work (the poll-driven `engine.objects` populates — verified working on iOS).
  - Mouse panel: mode buttons send `mouse`/`set mouse_selection_mode`.
  - Sequence panel: present (note: live data is a known gap from the iPad spec; tapping selects).
  - Mouse: drag rotates, scroll zooms (the `NSEvent` path → `PyMOL_Button`/`Drag`); click-to-pick (`handleMouseUp` → ensure it calls the pick path like iOS `handleTap`; if it still sends LEFT-click, route it to `engine.pick(...)` with macOS NDC: point-space, `NSView` origin is bottom-left so NO Y-flip — the opposite of iOS).
- [ ] **Step 2: If click-pick on macOS doesn't select**, add a macOS pick mapping in `MetalViewport.swift`'s `handleMouseUp` (or a dedicated click handler) computing NDC from the `NSEvent` location in the view (bottom-left origin, point space, no Y-flip) and calling `engine.pick(ndcX:ndcY:aspect:)`. Build + verify a click selects (pink indicator).
- [ ] **Step 3: Add a minimal app menu** if the default SwiftUI menu is insufficient for parity (File→Open to `cmd.load`, basic Edit). Keep small.
- [ ] **Step 4: Commit** any macOS input/menu fixes:
```bash
git add -A swiftui/PyMOLViewer
git commit -m "feat(macos): macOS click-pick + menu parity for the SwiftUI app"
```

> **Checkpoint C:** a user can load/represent/select/run-commands on Mac entirely through the SwiftUI panels + mouse/keyboard, without the AppKit app (chat excepted).

---

## Phase D — Sign + run standalone

### Task D1: Entitlements + inside-out ad-hoc signing

**Files:** Create `swiftui/PyMOLViewer/Resources/PyMOLViewer.entitlements`; Modify `swiftui/project.yml`.

- [ ] **Step 1: Write the entitlements** (required for ad-hoc dylibs under hardened runtime — empirically verified on this Mac):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict>
</plist>
```
- [ ] **Step 2: Wire it + hardened runtime** in `project.yml` (macOS-scoped settings):
```yaml
    settings:
      base:
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": PyMOLViewer/Resources/PyMOLViewer.entitlements
        "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": YES
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "-"
```
- [ ] **Step 3: Add the inside-out ad-hoc signing phase** as the LAST macOS `postBuildScript` (so it runs after the bundling phases; signs nested Mach-O before the app):
```yaml
      - name: "macOS: Ad-hoc sign embedded Python (inside-out)"
        basedOnDependencyAnalysis: false
        script: |
          case "$PLATFORM_NAME" in macosx*) ;; *) exit 0 ;; esac
          set -e
          APP="$CODESIGNING_FOLDER_PATH"
          ENT="$SRCROOT/PyMOLViewer/Resources/PyMOLViewer.entitlements"
          # 1) every nested .so / .dylib first (inside-out); NOT --deep
          find "$APP/Contents/Resources/python" \( -name '*.so' -o -name '*.dylib' \) -print0 \
            | xargs -0 -I{} codesign --force --options runtime --timestamp=none --sign - "{}"
          # 2) the main executable + app are signed by Xcode's own CodeSign step
          #    using CODE_SIGN_ENTITLEMENTS above; this phase only covers the
          #    embedded Python payload that Xcode doesn't know about.
```
(Xcode's built-in CodeSign step signs the app executable + bundle last with the entitlements; this phase pre-signs the embedded Python tree it doesn't track.)
- [ ] **Step 4: Rebuild + verify signing**
```bash
cd swiftui && xcodegen generate && cd ..   # (then canonical build)
codesign --verify --deep --strict --verbose=2 "$APP"   # expect: valid on disk
codesign -dvvv "$APP" 2>&1 | grep -E 'flags|Signature|TeamIdentifier'  # adhoc, runtime
codesign -d --entitlements - "$BIN" 2>&1 | grep disable-library-validation
```
- [ ] **Step 5: Commit**
```bash
git add swiftui/PyMOLViewer/Resources/PyMOLViewer.entitlements swiftui/project.yml swiftui/PyMOLViewer.xcodeproj
git commit -m "build(macos): entitlements + inside-out ad-hoc signing of embedded Python"
```

### Task D2: Verify a copied bundle launches via Finder

**Files:** none (verification).

- [ ] **Step 1: Copy the bundle to a fresh location** (a copy carries no quarantine xattr):
```bash
rm -rf /tmp/PyMOLViewer.app && cp -R "$APP" /tmp/PyMOLViewer.app
xattr -r /tmp/PyMOLViewer.app | grep com.apple.quarantine || echo "no quarantine (good)"
```
- [ ] **Step 2: Launch the copy via the GUI path** and screenshot:
```bash
open /tmp/PyMOLViewer.app
sleep 6; screencapture -o -x /tmp/pymol_mac_copied.png
```
Expected: the copied app launches from Finder/`open` and renders (load a structure via the command panel to confirm, or temporarily set autoload). If Finder blocks it (only happens if quarantined), document `xattr -dr com.apple.quarantine`.
- [ ] **Step 3: Document the notarization-when-Developer-ID steps** in the spec/README as a gated follow-up (replace `--sign -` with the Developer ID identity + `--timestamp`, `xcrun notarytool submit --wait`, `xcrun stapler staple`).

> **Checkpoint D (DoD):** a **copied** `PyMOLViewer.app` (no quarantine) launches via Finder on this Mac and renders the cartoon via Metal; `codesign --verify --deep --strict` passes; no Homebrew/system-Python dependency.

---

## Self-review (against the spec)

**Spec coverage:** DoD#1 native SwiftUI Mac app → Phase B. DoD#2 render via Metal + mouse pick → B3 + C1. DoD#3 non-chat panels + input + menu → Phase C. DoD#4 self-contained (embedded Python, no Homebrew) → A1/A3/B1/B2 + B3 Step 4 check. DoD#5 ad-hoc signed + copied-bundle launch → Phase D. Spec §5 decisions: python-build-standalone → A1; rebuild core against it → A2/A3; metallib `--sdk macosx` → B2; macOS-guarded xcodegen phases → B2/D1; ad-hoc first → D1. ✓

**Placeholder scan:** the freetype/png runtime-dep note (B1) and the optional Python-trim (B2) are flagged decisions with concrete fallbacks, not placeholders. The optional-import guard (B3 Step 2) references the concrete iOS precedent. No "TBD"/"handle errors". ✓

**Type/name consistency:** `PYMOL_METAL_ONLY` (CMake) ↔ `_PYMOL_METAL_ONLY` (define) ↔ the `main_ios.cpp` guard ↔ `build_macos.sh` flags ↔ xcconfig `build_macos_swiftui` path are consistent. `config.home=<res>/python` + `lib/python3.13` matches the standalone layout and the shared `PyMOLBridge_InitPython` (unchanged). ✓

**Assumptions to confirm at execution (flagged, not placeholders):** exact line numbers in `appkit/CMakeLists.txt` for the `PYMOL_IOS` guards (the task says read + match); whether `PYMOL_PYTHON_INCLUDE_DIR`/`PYMOL_PYTHON_LIBRARY` are the right cache-var names the CMakeLists' Python-find logic consumes (adjust to the file's actual variables); whether freetype/png resolve without Homebrew at runtime.
