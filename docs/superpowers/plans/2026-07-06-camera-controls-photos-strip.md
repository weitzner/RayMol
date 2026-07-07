# Camera controls — Photos-style icon strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace RayMol's bottom camera overlay with a slim, Photos-style bottom-docked icon strip where one control opens at a time, on all platforms.

**Architecture:** A new `CameraDock` SwiftUI view renders a strip of icon buttons (`Lens`, `Zoom`, `Ortho`, `Depth`, `Reset`). Slider controls (`Lens`/`Zoom`) open a single reused `SceneParamRow` above the strip; `Ortho` toggles instantly; `Depth` opens a compact `DOFSubPanelContent` card. All camera control *logic* is inherited from the existing `SceneParamRow` and PyMOL commands — this is a re-presentation layer, not new control logic. The dock replaces both today's iPhone `cameraGlassCard` and the macOS/iPad popover.

**Tech Stack:** Swift / SwiftUI (targets `PyMOLViewer_iOS`, `PyMOLViewer_macOS`); C++17 core (`layer1/SettingInfo.h`); XCUITest (`PyMOLViewerUITests`); Metal renderer (`RendererMetal`).

## Global Constraints

- **No control-logic duplication.** Reuse `SceneParamRow` (`ObjectPanel.swift:2047`) for every slider/DOF control. The only extracted helper is `CameraCommands.setAutofocus`.
- **Same component on all platforms.** iPhone, iPad, and macOS all use `CameraDock` docked at `.overlay(alignment: .bottom)`. The old macOS/iPad `.popover` is removed.
- **Dock chrome matches the old card:** `.ultraThinMaterial` in a `RoundedRectangle(cornerRadius: 22, style: .continuous)` with a `0.5px .white.opacity(0.14)` stroke, so reused `SceneParamRow` text (which uses `PanelTheme.textColor`) stays readable.
- **Icon active-state colors follow the existing selected-control precedent** (`SegmentedSetting`, `ObjectPanel.swift:1366-1367`): active disc = `PanelTheme.selectionTextColor` fill + black glyph; idle disc = `PanelTheme.buttonBackground` fill + `PanelTheme.buttonText` glyph.
- **SF Symbols:** `field_of_view`→`camera.aperture`, `zoom`→`plus.magnifyingglass`, `ortho`→`cube`, `metal_dof`→`camera.metering.center.weighted`, Reset→`dot.viewfinder`.
- **Accessibility identifiers (test contract):** strip buttons `camDock.lens` / `camDock.zoom` / `camDock.ortho` / `camDock.depth` / `camDock.reset`; DOF toggles `dof.enabled` / `dof.autolock`. The camera chip keeps id `camera` / label `Camera settings` (unchanged).
- **`metal_dof_quality` default = 4** (was 1); it is removed from the camera dock and remains only in the inspector's Scene → Camera group.
- **Copy is sentence case**, no terminal punctuation on labels.
- **Two-stage build always:** run the core script (`build_macos.sh` / `build_ios.sh simulator`) BEFORE `xcodebuild`, or xcodebuild links a stale `libpymol_core.a`.

---

## File structure

- `layer1/SettingInfo.h` — DOF quality default (Task 1).
- `layerGraphics/metal/RendererMetal.h` — `_dofQuality` member init (Task 1).
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — new `CameraStripCatalog` data + `cameraIcon`, `CameraCommands`, `CameraDock`, `DOFSubPanelContent`; refactor `SceneParamRow` autofocus case; remove `CameraControlsView` + `cameraOverlayKeys` (Tasks 2, 3).
- `swiftui/PyMOLViewer/Shared/ContentView.swift` — wire `CameraDock`; remove `cameraGlassCard`, `cameraPanelPresentation` (Task 3).
- `swiftui/PyMOLViewerUITests/CameraOverlayUITests.swift` — rewrite for the strip (Task 3).

---

### Task 1: DOF quality default → 4

**Files:**
- Modify: `layer1/SettingInfo.h:940`
- Modify: `layerGraphics/metal/RendererMetal.h:513`

- [ ] **Step 1: Change the setting default**

In `layer1/SettingInfo.h:940`, change the default field (last argument) from `1` to `4`:

```cpp
  REC_i( 830, metal_dof_quality                       , global    , 4 ),     /* Metal depth-of-field: bokeh quality level 1..4. Higher traces more gather samples (1->16, 2->32, 3->64, 4->96) for denser, cleaner out-of-focus blur; levels >=2 also run a de-noise smoothing pass (two-pass). 1 = fast single-pass. */
```

- [ ] **Step 2: Match the renderer member initializer**

In `layerGraphics/metal/RendererMetal.h:513`, change the initializer so the member matches the setting default before the first `setDofQuality`:

```cpp
  int _dofQuality = 4;         // cSetting_metal_dof_quality: 1..4 bokeh quality
```

- [ ] **Step 3: Build the desktop core and verify the default headlessly**

Build the Python/C++ core (see `memory/project_build_steps.md` for macOS/Homebrew specifics):

Run: `pip install --verbose --no-build-isolation --config-settings testing=True .`
Then: `pymol -cq -d "from pymol import cmd; v=float(cmd.get('metal_dof_quality')); assert abs(v-4.0)<0.5, v; print('metal_dof_quality default =', v)"`
Expected: `metal_dof_quality default = 4.0`

(Note: `metal_dof` itself remains OFF by default, so quality=4 costs nothing until a user enables depth of field.)

- [ ] **Step 4: Commit**

```bash
git add layer1/SettingInfo.h layerGraphics/metal/RendererMetal.h
git commit -m "feat(dof): default metal_dof_quality to 4 (best)"
```

---

### Task 2: Camera catalog data + shared autofocus command

Additive and behavior-preserving. Adds the strip's data + icon map and extracts the one duplicated command; touches no UI wiring, so the existing overlay and its UI tests keep working.

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (add to `enum SceneCatalog` ~line 189; add `CameraCommands`; edit `SceneParamRow` autofocus case ~2082-2090)

**Interfaces:**
- Produces: `SceneCatalog.cameraStripKeys: [String]`, `SceneCatalog.cameraIcon(for:) -> String`, `CameraCommands.setAutofocus(_ on: Bool) -> String` — consumed by Task 3.

- [ ] **Step 1: Add the strip catalog + icon map to `SceneCatalog`**

Inside `enum SceneCatalog` (after `cameraOverlayKeys`, ~line 198 in `ObjectPanel.swift`), add:

```swift
    // Viewport camera dock (see CameraDock): the always-visible strip icons, in
    // order. DOF's sub-controls are rendered by DOFSubPanelContent, not as strip
    // icons. metal_dof_quality is intentionally absent — it defaults to best (4)
    // and lives only in the inspector's Scene → Camera group.
    static let cameraStripKeys = ["field_of_view", "zoom", "ortho", "metal_dof"]

    // SF Symbol for each strip control.
    static func cameraIcon(for setting: String) -> String {
        switch setting {
        case "field_of_view": return "camera.aperture"
        case "zoom":          return "plus.magnifyingglass"
        case "ortho":         return "cube"
        case "metal_dof":     return "camera.metering.center.weighted"
        default:              return "slider.horizontal.3"
        }
    }
```

- [ ] **Step 2: Add the `CameraCommands` helper**

Immediately after the `SceneParam` struct's closing brace / before `enum SceneCatalog` (top-level in `ObjectPanel.swift`, ~line 188), add:

```swift
// Camera-control command strings shared by the inspector row and the camera dock,
// so the DOF auto-lock action has a single source of truth.
enum CameraCommands {
    // Auto-lock focus: enabling snapshots the current selection into "dof_focus"
    // (the target the renderer tracks each frame); disabling just clears the flag.
    static func setAutofocus(_ on: Bool) -> String {
        on ? "select dof_focus, (sele)\nset metal_dof_autofocus, 1"
           : "set metal_dof_autofocus, 0"
    }
}
```

- [ ] **Step 3: Refactor `SceneParamRow`'s autofocus case to use the helper**

In `SceneParamRow.sceneControl` (`ObjectPanel.swift`, the `if p.setting == "metal_dof_autofocus"` branch, ~2082-2090), replace the inline command with the helper:

```swift
                if p.setting == "metal_dof_autofocus" {
                    // Enabling snapshots the current selection into "dof_focus" —
                    // the locked target the renderer tracks each frame (see the
                    // SceneRender auto-focus block). Disabling just clears the flag.
                    ToggleSetting(value: v) { on in
                        engine.runCommand(CameraCommands.setAutofocus(on))
                    }
                } else {
```

- [ ] **Step 4: Build the iOS app to confirm it compiles**

Run: `cd swiftui && ./build_ios.sh simulator && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: `** BUILD SUCCEEDED **` (if `iPhone 16` is absent, pick an available device from `xcrun simctl list devices available`).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift
git commit -m "feat(camera): add camera-dock catalog + shared autofocus command"
```

---

### Task 3: Build the camera dock, wire it in, and swap the tests (TDD)

The core change. Rewrite the UI tests to the strip contract first (they fail against the old overlay), implement `CameraDock`, wire it on all platforms, remove the old overlay, then make the tests pass on the simulator.

**Files:**
- Modify: `swiftui/PyMOLViewerUITests/CameraOverlayUITests.swift` (rewrite)
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (add `CameraDock`, `DOFSubPanelContent`; remove `CameraControlsView` ~2195-2231 and `cameraOverlayKeys` ~195-198)
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (wire dock; remove `cameraGlassCard` ~2462-2486 and `cameraPanelPresentation` ~2438-2456; edit `bottomLeadingViewportChrome` ~2429-2431; add macOS overlay ~390)

**Interfaces:**
- Consumes: `SceneCatalog.cameraStripKeys`, `SceneCatalog.cameraIcon(for:)`, `CameraCommands.setAutofocus`, `SceneParamRow`, `SceneCatalog.param(for:)`, and the file-private `ToggleSetting` / `PanelTheme` (all in `ObjectPanel.swift`).
- Produces: `CameraDock(engine: PyMOLEngine)` — an `internal` View consumed by `ContentView`.

- [ ] **Step 1: Rewrite the UI tests to the strip contract**

Replace the entire body of `swiftui/PyMOLViewerUITests/CameraOverlayUITests.swift` with:

```swift
// CameraOverlayUITests.swift — functional verification of the camera chip and the
// bottom-docked camera control strip (CameraDock) on iPhone (compact size class).
//
// AX contract (see CameraDock):
//   - Camera chip:  id='camera', label='Camera settings'
//   - Strip icons:  id='camDock.lens' / '.zoom' / '.ortho' / '.depth' / '.reset'
//   - DOF toggles:  id='dof.enabled' / 'dof.autolock'
//   - Open control: the only slider in the app when a slider surface is open.

import XCTest

final class CameraOverlayUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_AUTOCMD"] = "hide everything; show cartoon; orient"
    }

    // MARK: - Chip opens a strip of icons, no surface yet

    func testChipOpensStrip() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        let chip = cameraChipButton()
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Camera chip not found")
        attach("strip_1_chip")

        chip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach("strip_2_open")

        for id in ["camDock.lens", "camDock.zoom", "camDock.ortho", "camDock.depth", "camDock.reset"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "Strip icon '\(id)' not found")
        }
        // No surface open yet → no slider present (Objects panel is closed).
        XCTAssertFalse(app.sliders.firstMatch.exists, "A slider is open before any icon was tapped")
    }

    // MARK: - Lens/Zoom open a single slider, one at a time

    func testLensAndZoomOpenSingleSlider() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.lens"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3), "Lens slider did not open")
        attach("strip_3_lens")

        // Tapping the active icon again collapses the surface.
        app.buttons["camDock.lens"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.sliders.firstMatch.exists, "Lens slider did not collapse on second tap")

        app.buttons["camDock.zoom"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3), "Zoom slider did not open")
        attach("strip_4_zoom")
    }

    // MARK: - Ortho toggles and disables Lens

    func testOrthoDisablesLens() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        let lens = app.buttons["camDock.lens"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5), "Lens icon not found")
        XCTAssertTrue(lens.isEnabled, "Lens should be enabled in perspective mode")

        app.buttons["camDock.ortho"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach("strip_5_ortho")
        XCTAssertFalse(lens.isEnabled, "Lens should be disabled in orthographic mode")

        // Turn ortho back off so the run leaves a clean state.
        app.buttons["camDock.ortho"].tap()
    }

    // MARK: - Depth opens the sub-panel; enabling reveals Focus; no quality control

    func testDepthSubPanel() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.depth"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.staticTexts["Depth of field"].waitForExistence(timeout: 3),
                      "DOF sub-panel header not shown")

        let enabled = app.switches["dof.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3), "DOF 'Enabled' toggle not found")

        // Focus/aperture are hidden until DOF is enabled.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.exists,
                       "Focus row should be hidden before DOF is enabled")
        enabled.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach("strip_6_dof")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.waitForExistence(timeout: 3),
                      "Focus row not revealed after enabling DOF")

        // Quality was moved to the inspector — it must NOT appear in the dock.
        XCTAssertFalse(app.staticTexts["DOF quality"].exists,
                       "'DOF quality' must not appear in the camera dock")
    }

    // MARK: - Reset does not crash

    func testResetNoCrash() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        let reset = app.buttons["camDock.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Reset icon not found")
        reset.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "App crashed after Reset")
        attach("strip_7_reset")
    }

    // MARK: - Zoom slider changes the on-screen molecule size

    func testZoomChangesView() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.zoom"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        let zoom = app.sliders.firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 3), "Zoom slider not open")

        let baseline = viewportMoleculeSize()
        zoom.adjust(toNormalizedSliderPosition: 0.75)
        Thread.sleep(forTimeInterval: 1.5)
        let zoomedIn = viewportMoleculeSize()
        attach("strip_8_zoomin")
        zoom.adjust(toNormalizedSliderPosition: 0.10)
        Thread.sleep(forTimeInterval: 1.5)
        let zoomedOut = viewportMoleculeSize()

        XCTAssertGreaterThan(zoomedIn, baseline, "Molecule did not grow when zooming in")
        XCTAssertLessThan(zoomedOut, baseline, "Molecule did not shrink when zooming out")
    }

    // MARK: - Helpers

    private func cameraChipButton() -> XCUIElement {
        let byID = app.buttons["camera"]
        if byID.exists { return byID }
        return app.buttons["Camera settings"]
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func waitForRender(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewportMoleculeSize() > 200 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func viewportMoleculeSize() -> Int {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        let crop = CGRect(x: Int(Double(w) * 0.20), y: Int(Double(h) * 0.05),
                          width: Int(Double(w) * 0.60), height: Int(Double(h) * 0.60))
        guard let region = cg.cropping(to: crop) else { return 0 }
        let pw = region.width, ph = region.height
        var buf = [UInt8](repeating: 0, count: pw * ph * 4)
        guard let ctx = CGContext(data: &buf, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        var count = 0
        for i in stride(from: 0, to: buf.count, by: 4) where Int(buf[i]) + Int(buf[i+1]) + Int(buf[i+2]) > 60 { count += 1 }
        return count
    }
}
```

- [ ] **Step 2: Run the rewritten tests to verify they FAIL against the old UI**

Run: `cd swiftui && ./build_ios.sh simulator && xcodebuild test -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:PyMOLViewerUITests/CameraOverlayUITests/testChipOpensStrip`
Expected: FAIL — `Strip icon 'camDock.lens' not found` (the old overlay has no such identifiers).

- [ ] **Step 3: Add `DOFSubPanelContent` to `ObjectPanel.swift`**

Add near `CameraControlsView` (which you will remove in Step 6):

```swift
// The Depth-of-field sub-panel shown inside the camera dock when "Depth" is
// selected. Enabled + Auto lock share the top row (both switches); Focus and
// Aperture reuse the inspector rows and self-hide (dependsOn: metal_dof) until
// DOF is enabled. Quality is intentionally not here — it lives in the inspector.
struct DOFSubPanelContent: View {
    @ObservedObject var engine: PyMOLEngine
    private var dofOn: Bool { (engine.sceneState.values["metal_dof"] ?? 0) > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "camera.metering.center.weighted")
                Text("Depth of field").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundColor(PanelTheme.textColor)
            .padding(.bottom, 2)

            HStack(spacing: 20) {
                dofToggle("Enabled", key: "metal_dof", id: "dof.enabled", enabled: true) { on in
                    engine.runCommand("set metal_dof, \(on ? 1 : 0)")
                }
                dofToggle("Auto lock", key: "metal_dof_autofocus", id: "dof.autolock", enabled: dofOn) { on in
                    engine.runCommand(CameraCommands.setAutofocus(on))
                }
                Spacer()
            }

            if let focus = SceneCatalog.param(for: "metal_dof_focus") {
                SceneParamRow(param: focus, engine: engine)
            }
            if let aperture = SceneCatalog.param(for: "metal_dof_aperture") {
                SceneParamRow(param: aperture, engine: engine)
            }
        }
    }

    private func dofToggle(_ label: String, key: String, id: String,
                           enabled: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(PanelTheme.textColor)
            ToggleSetting(value: engine.sceneState.values[key] ?? 0, onToggle: onToggle)
                .accessibilityIdentifier(id)
                .accessibilityLabel(label)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
```

- [ ] **Step 4: Add `CameraDock` to `ObjectPanel.swift`**

Add after `DOFSubPanelContent`:

```swift
// Bottom-docked camera control strip (Photos-app "Adjust" model): a row of icon
// buttons where one control opens at a time above the strip. Reuses SceneParamRow
// for every slider control so all camera logic stays in one place. Used on all
// platforms via ContentView's bottom overlay.
struct CameraDock: View {
    @ObservedObject var engine: PyMOLEngine
    // Which control's surface is open above the strip. nil = strip only.
    // "ortho" toggles instantly and never becomes `open`.
    @State private var open: String? = nil

    private var orthoOn: Bool { (engine.sceneState.values["ortho"] ?? 0) > 0.5 }
    private var dofOn: Bool { (engine.sceneState.values["metal_dof"] ?? 0) > 0.5 }

    var body: some View {
        VStack(spacing: 8) {
            if let key = open {
                Group {
                    if key == "metal_dof" {
                        DOFSubPanelContent(engine: engine)
                    } else if let p = SceneCatalog.param(for: key) {
                        SceneParamRow(param: p, engine: engine)
                    }
                }
                .padding(.horizontal, 4)
                Divider().overlay(PanelTheme.textColor.opacity(0.15))
            }
            HStack(spacing: 10) {
                ForEach(SceneCatalog.cameraStripKeys, id: \.self) { stripIcon($0) }
                stripAction(icon: "dot.viewfinder", label: "Reset", id: "camDock.reset") {
                    engine.runCommand("reset")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.18), value: open)
    }

    private func tap(_ key: String) {
        switch key {
        case "ortho":
            let newVal = orthoOn ? 0 : 1
            engine.runCommand("set ortho, \(newVal)")
            if newVal == 1 && open == "field_of_view" { open = nil }  // Lens is inert in ortho
        default:
            open = (open == key) ? nil : key
        }
    }

    @ViewBuilder
    private func stripIcon(_ key: String) -> some View {
        let selected = (open == key)
        let on = (key == "ortho" && orthoOn)
        let active = selected || on
        let disabled = (key == "field_of_view" && orthoOn)
        Button { tap(key) } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: SceneCatalog.cameraIcon(for: key))
                        .font(.system(size: 17))
                        .foregroundColor(active ? .black : PanelTheme.buttonText)
                        .frame(width: 42, height: 42)
                        .background(active ? PanelTheme.selectionTextColor : PanelTheme.buttonBackground,
                                    in: Circle())
                    if key == "metal_dof" && dofOn {
                        Circle().fill(PanelTheme.selectionTextColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .offset(x: 2, y: -2)
                    }
                }
                Text(shortLabel(key)).font(.system(size: 10))
                    .foregroundColor(active ? PanelTheme.selectionTextColor : PanelTheme.textColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityIdentifier(axID(key))
        .accessibilityLabel(fullLabel(key))
    }

    private func stripAction(icon: String, label: String, id: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(PanelTheme.buttonText)
                    .frame(width: 42, height: 42)
                    .background(PanelTheme.buttonBackground, in: Circle())
                Text(label).font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel("Reset view")
    }

    private func shortLabel(_ key: String) -> String {
        switch key {
        case "field_of_view": return "Lens"
        case "zoom":          return "Zoom"
        case "ortho":         return "Ortho"
        case "metal_dof":     return "Depth"
        default:              return key
        }
    }
    private func fullLabel(_ key: String) -> String {
        switch key {
        case "field_of_view": return "Lens"
        case "zoom":          return "Zoom"
        case "ortho":         return "Orthographic"
        case "metal_dof":     return "Depth of field"
        default:              return key
        }
    }
    private func axID(_ key: String) -> String {
        switch key {
        case "field_of_view": return "camDock.lens"
        case "zoom":          return "camDock.zoom"
        case "ortho":         return "camDock.ortho"
        case "metal_dof":     return "camDock.depth"
        default:              return "camDock.\(key)"
        }
    }
}
```

- [ ] **Step 5: Wire `CameraDock` into `ContentView` (iOS + iPad)**

In `ContentView.swift`, replace the compact-only camera overlay block (~1445-1451) with an all-width dock (drop the `hSize == .compact` gate):

```swift
            // Camera control dock: a bottom-docked icon strip (one control open at
            // a time). Same component on iPhone / iPad. Drag down or tap the chip
            // to dismiss.
            .overlay(alignment: .bottom) {
                if showCameraPanel && !engine.objects.isEmpty {
                    CameraDock(engine: engine)
                        .padding(.horizontal, 10)
                        .padding(.bottom, engine.hasTimeline ? 84 : 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .gesture(DragGesture().onEnded { v in
                            if v.translation.height > 40 {
                                withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false }
                            }
                        })
                }
            }
```

- [ ] **Step 6: Wire `CameraDock` into `ContentView` (macOS) and simplify the chip**

In the macOS viewport, immediately after the `.overlay(alignment: .bottomLeading) { bottomLeadingViewportChrome ... }` block (~386-390), add the same dock overlay:

```swift
                        .overlay(alignment: .bottom) {
                            if showCameraPanel && !engine.objects.isEmpty {
                                CameraDock(engine: engine)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, engine.hasTimeline ? 84 : 12)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .gesture(DragGesture().onEnded { v in
                                        if v.translation.height > 40 {
                                            withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false }
                                        }
                                    })
                            }
                        }
```

In `bottomLeadingViewportChrome` (~2429-2431), the chip no longer needs the popover wrapper:

```swift
            if !engine.objects.isEmpty {
                cameraButton
            }
```

- [ ] **Step 7: Remove the now-dead old overlay code**

Delete these (all now unused):
- `cameraPanelPresentation<V: View>(_:)` — `ContentView.swift` ~2438-2456.
- `cameraGlassCard` — `ContentView.swift` ~2462-2486.
- `CameraControlsView` — `ObjectPanel.swift` ~2195-2231.
- `cameraOverlayKeys` — `ObjectPanel.swift` ~195-198.

Then confirm nothing references them:

Run: `cd swiftui && grep -rn "cameraGlassCard\|cameraPanelPresentation\|CameraControlsView\|cameraOverlayKeys" PyMOLViewer/`
Expected: no output.

- [ ] **Step 8: Build both apps**

Run: `cd swiftui && ./build_macos.sh && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug`
Expected: `** BUILD SUCCEEDED **`
Run: `cd swiftui && ./build_ios.sh simulator && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Run the full rewritten UI test suite on the simulator — verify PASS**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:PyMOLViewerUITests/CameraOverlayUITests`
Expected: `** TEST SUCCEEDED **` — all of `testChipOpensStrip`, `testLensAndZoomOpenSingleSlider`, `testOrthoDisablesLens`, `testDepthSubPanel`, `testResetNoCrash`, `testZoomChangesView` pass. Review the attached screenshots (`strip_*`) to confirm the dock is slim and the molecule stays visible.

- [ ] **Step 10: Commit**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewerUITests/CameraOverlayUITests.swift
git commit -m "feat(camera): Photos-style bottom-docked control strip (all platforms)"
```

---

### Task 4: macOS functional verification in an isolated VM

The UI tests cover iOS; this confirms the same dock on macOS with a pointer.

**Files:** none (verification only)

- [ ] **Step 1: Build the macOS app (two-stage)**

Run: `cd swiftui && ./build_macos.sh && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Launch in a disposable VM and drive the dock**

Use the `mac-vm-test` skill (or `raymol-mac-vm` for MCP control) to run the built app in an isolated VM. Then:
1. Load a structure (e.g. `fetch 1ubq, async=0; hide everything; show cartoon; orient`).
2. Click the camera chip (bottom-left) → confirm the dock appears centered at the bottom, slim, molecule fully visible.
3. Click `Depth` → confirm the DOF sub-panel opens with `Enabled` and `Auto lock` side by side.
4. Toggle `Enabled` → confirm `Focus` and `Aperture` sliders appear (and DOF renders).
5. Click `Ortho` → confirm the `Lens` icon greys out.
6. Click `Reset`, then drag the dock down → confirm it dismisses without crashing.

Acceptance: screenshots show the slim bottom dock replacing the old popover, one control open at a time, on macOS.

- [ ] **Step 3: Verify quality relocation in the inspector**

In the same VM session, open the inspector Scene panel → Camera group and confirm `DOF quality` is present there and reads `4` by default, and is absent from the camera dock.

- [ ] **Step 4: Commit any test-support tweaks (if needed)**

If no code changed, nothing to commit. Otherwise:

```bash
git add -A && git commit -m "test(camera): macOS VM verification notes"
```

---

## Notes for the executor

- After Task 3 Step 1 the UI tests are intentionally RED until Step 9 — that is the TDD anchor, not a regression.
- If `iPhone 16` is not an available simulator, substitute any available iPhone from `xcrun simctl list devices available` in every `-destination` above.
- The dock reuses `SceneParamRow`, which reads the ~500ms-lagged `engine.sceneState` poll; the optimistic `ToggleSetting`/`LabeledSlider` local state (already in those views) keeps the controls responsive.
