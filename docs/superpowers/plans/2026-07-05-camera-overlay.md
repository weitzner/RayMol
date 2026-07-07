# Camera-settings overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bottom-left viewport camera button that opens a compact camera-settings overlay (popover on macOS/iPad, bottom sheet on iPhone), reusing the inspector's existing scene-control rows.

**Architecture:** Extract the inspector's per-row rendering into a reusable `SceneParamRow` view so the overlay and the inspector share one implementation. A new `CameraControlsView` renders a curated ordered subset of the "Camera" scene params plus a Reset view button. `ContentView` gains a `CameraButton` chip in the existing bottom-leading viewport overlay and presents `CameraControlsView` via `.popover` (regular width) or `.sheet` (compact width).

**Tech Stack:** SwiftUI (macOS + iOS), the existing `PyMOLEngine` / `SceneParam` / `SceneCatalog` infrastructure. No C++/core, no `.pse`/settings, no renderer changes.

## Global Constraints

- Swift-only change. Do NOT run `bash swiftui/build_macos.sh` (no C++ core changed).
- No new files (avoids Xcode project wiring): `SceneParamRow` and `CameraControlsView` are added to `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (they need `SceneParam`/`SceneCatalog`/`LabeledSlider`/`ToggleSetting`/`PanelTheme`, all in that module); `CameraButton` + presentation glue go in `swiftui/PyMOLViewer/Shared/ContentView.swift`.
- Single source of truth: the overlay reuses `SceneParamRow`; the inspector keeps the same rows and behavior after extraction.
- Verification is **build success + functional sim/VM check**, not unit tests (these are SwiftUI views; the repo has no XCUITest harness for them). SourceKit "Cannot find type …" diagnostics are false positives — trust `xcodebuild`.
- `ortho` is already in `appkit_inspector.py` `SCENE_SETTINGS`, so it persists across screens — no Python change needed.
- Build commands:
  - macOS: `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd build`
  - iOS sim: `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -sdk iphonesimulator -configuration Debug -derivedDataPath swiftui/build_ios_sim_dd build`

---

### Task 1: Catalog data — rename autofocus, add Orthographic, add overlay key list

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (SceneCatalog params ~204–216; enum body ~189–192)

**Interfaces:**
- Produces: `SceneCatalog.cameraOverlayKeys: [String]`, `SceneCatalog.param(for:) -> SceneParam?`; a new `ortho` SceneParam in the "Camera" group; renamed `metal_dof_autofocus` label "Auto lock focus".

- [ ] **Step 1: Rename the autofocus label.** In the `metal_dof_autofocus` SceneParam (~208), change `label: "Autofocus (lock to selection)"` to `label: "Auto lock focus"`. Leave its `help:` text unchanged.

- [ ] **Step 2: Add the Orthographic param** immediately AFTER the `field_of_view` SceneParam (~205) so it renders right after Lens in both the inspector and the overlay:

```swift
        SceneParam(setting: "ortho", label: "Orthographic", kind: .toggle, group: "Camera",
                   help: "Orthographic (parallel) projection — no perspective. Disables the Lens control."),
```

- [ ] **Step 3: Add the overlay key list + lookup** to the `SceneCatalog` enum (after `static let params` closes, ~inside the enum):

```swift
    // Ordered subset shown in the viewport Camera overlay (a shortcut to the
    // most-used camera controls). Deliberately omits metal_dof_range and
    // depth_cue, which remain in the full inspector.
    static let cameraOverlayKeys = [
        "field_of_view", "ortho", "metal_dof",
        "metal_dof_autofocus", "metal_dof_focus", "metal_dof_aperture", "metal_dof_hq",
    ]
    static func param(for setting: String) -> SceneParam? {
        params.first { $0.setting == setting }
    }
```

- [ ] **Step 4: Build macOS.** Run the macOS build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Build iOS sim.** Run the iOS sim build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit.**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift
git commit -m "feat(camera-overlay): rename autofocus label, add Orthographic param + overlay key list"
```

---

### Task 2: Extract `SceneParamRow` (refactor, no behavior change)

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — add `struct SceneParamRow`; rewrite the scene-group ForEach (~1993–1995) to use it; delete the now-moved private helpers from the scene-panel view (`visible`, `paramRow`, `sceneControl`, `fmtScene`, `fovToMM`, `mmToFOV`, `setBackground`, `setOutlineColor`, `sceneRow`).

**Interfaces:**
- Consumes: `SceneParam`, `PyMOLEngine`, `LabeledSlider`, `ToggleSetting`, `SegmentedSetting`, `DebouncedColorPicker`, `HelpButton`, `RepProperty`, `PanelTheme`, `rgb01List` (all module-visible).
- Produces: `SceneParamRow(param: SceneParam, engine: PyMOLEngine)` — a self-gating row view (renders `EmptyView` when its `dependsOn` parent is off).

- [ ] **Step 1: Add the `SceneParamRow` struct** (place it just before `enum SceneCatalog` or right after it, at file scope). This assembles the existing `paramRow`/`sceneControl`/`sceneRow` + helpers verbatim into a view, self-gating on `dependsOn`:

```swift
// One scene-setting row (label + control + help), shared by the inspector's
// Scene section and the viewport Camera overlay. Self-hides when its dependsOn
// parent toggle is off, so callers can render it unconditionally.
struct SceneParamRow: View {
    let param: SceneParam
    @ObservedObject var engine: PyMOLEngine

    var body: some View {
        if let dep = param.dependsOn, (engine.sceneState.values[dep] ?? 0) <= 0.5 {
            EmptyView()
        } else {
            let rtUnavailable = param.setting == "metal_raytrace" && !engine.rayTracingSupported
            sceneRow(rtUnavailable ? "\(param.label) (unavailable)" : param.label, help: param.help) {
                sceneControl(param)
            }
            .padding(.leading, param.dependsOn != nil ? 12 : 0)
            .disabled(rtUnavailable)
            .opacity(rtUnavailable ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private func sceneControl(_ p: SceneParam) -> some View {
        if p.isColor {
            DebouncedColorPicker(
                get: {
                    let c = (p.setting == "bg_rgb") ? engine.sceneState.bg : engine.sceneState.outlineColor
                    return Color(.sRGB, red: c.count > 0 ? c[0] : 0,
                                 green: c.count > 1 ? c[1] : 0, blue: c.count > 2 ? c[2] : 0)
                },
                apply: { c in
                    if p.setting == "bg_rgb" { setBackground(c) } else { setOutlineColor(c) }
                })
                .frame(width: 28)
        } else {
            let v = engine.sceneState.values[p.setting] ?? 0
            switch p.kind {
            case .toggle:
                if p.setting == "metal_dof_autofocus" {
                    ToggleSetting(value: v) { on in
                        engine.runCommand(on
                            ? "select dof_focus, (sele)\nset metal_dof_autofocus, 1"
                            : "set metal_dof_autofocus, 0")
                    }
                } else {
                    ToggleSetting(value: v) { on in engine.runCommand("set \(p.setting), \(on ? 1 : 0)") }
                }
            case .segmented:
                SegmentedSetting(prop: RepProperty(setting: p.setting, label: p.label, kind: .segmented, options: p.options),
                                 value: v) { engine.runCommand("set \(p.setting), \(Int($0))") }
            case .slider:
                if p.setting == "field_of_view" {
                    let fovDeg = engine.sceneState.values["field_of_view"] ?? 20
                    let orthoOn = (engine.sceneState.values["ortho"] ?? 0) > 0.5
                    LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                                    min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                                  value: fovToMM(fovDeg),
                                  onLive: { engine.runCommand("set_fov \(String(format: "%.3f", mmToFOV($0)))") },
                                  onCommit: { engine.runCommand("set_fov \(String(format: "%.3f", mmToFOV($0)))") })
                        .disabled(orthoOn)
                        .opacity(orthoOn ? 0.4 : 1.0)
                } else {
                    let dofAuto = p.setting == "metal_dof_focus"
                        && (engine.sceneState.values["metal_dof_autofocus"] ?? 0) > 0.5
                    LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                                    min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                                  value: v,
                                  onLive: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") },
                                  onCommit: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") })
                        .disabled(dofAuto)
                        .opacity(dofAuto ? 0.4 : 1.0)
                }
            case .color:
                EmptyView()
            }
        }
    }

    private func fmtScene(_ v: Double, _ p: SceneParam) -> String {
        p.decimals == 0 ? String(Int(v.rounded())) : String(format: "%.4f", v)
    }
    private func fovToMM(_ fovDeg: Double) -> Double {
        let f = 12.0 / tan(fovDeg * .pi / 360.0)
        return min(max(f, 12.0), 135.0)
    }
    private func mmToFOV(_ mm: Double) -> Double {
        2.0 * atan(12.0 / mm) * 180.0 / .pi
    }
    private func setBackground(_ color: Color) {
        engine.runCommand("set_color _bgcol, \(rgb01List(color))\nbg_color _bgcol")
    }
    private func setOutlineColor(_ color: Color) {
        engine.runCommand("set_color _outlinecol, \(rgb01List(color))\nset metal_outline_color, _outlinecol")
    }

    @ViewBuilder
    private func sceneRow<Content: View>(_ label: String, help: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
            if !help.isEmpty { HelpButton(text: help) }
        }
    }
}
```

- [ ] **Step 2: Rewrite the scene-group ForEach** in the scene-panel view (~1993–1995) to use `SceneParamRow` (which self-gates, so drop the `if visible(p)` wrapper):

```swift
            if isOpen {
                ForEach(SceneCatalog.params.filter { $0.group == group }) { p in
                    SceneParamRow(param: p, engine: engine)
                }
                if group == "Effects" { resetEffectsButton }
            }
```

- [ ] **Step 3: Delete the now-moved private helpers** from the scene-panel view struct: `visible(_:)` (~2026), `paramRow(_:)` (~2032), `sceneControl(_:)` (~2042), `fmtScene(_:_:)` (~2107), `fovToMM(_:)` (~2115), `mmToFOV(_:)` (~2119), `setBackground(_:)` (~2123), `setOutlineColor(_:)` (~2127), and `sceneRow(_:help:_:)` (~2131). Keep `resetEffects`/`resetEffectsButton`. If the compiler flags any of these as still-referenced elsewhere, leave that one in place.

- [ ] **Step 4: Build macOS.** Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Build iOS sim.** Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Functional check (macOS host or VM).** Open the inspector Scene → Camera group: Lens slider changes perspective; Orthographic toggles and greys Lens; Depth of field reveals Auto lock focus / Focus / Aperture / High quality; the Canvas Background color picker still works; Effects reset still works. Behavior identical to before the refactor.

- [ ] **Step 7: Commit.**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift
git commit -m "refactor(scene): extract reusable SceneParamRow view (no behavior change)"
```

---

### Task 3: `CameraControlsView` (shared overlay content)

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — add `struct CameraControlsView` at file scope (after `SceneParamRow`).

**Interfaces:**
- Consumes: `SceneCatalog.cameraOverlayKeys`, `SceneCatalog.param(for:)`, `SceneParamRow`, `PyMOLEngine`, `PanelTheme`.
- Produces: `CameraControlsView(engine: PyMOLEngine)` — the overlay body (header + camera rows + Reset view button).

- [ ] **Step 1: Add the view:**

```swift
// Content of the viewport Camera overlay (popover on macOS/iPad, bottom sheet on
// iPhone). Reuses SceneParamRow for the curated camera params, then a Reset view
// action. Reads/writes go through PyMOLEngine exactly as the inspector does.
struct CameraControlsView: View {
    @ObservedObject var engine: PyMOLEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "camera")
                Text("Camera").font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundColor(PanelTheme.textColor)
            .padding(.bottom, 2)

            ForEach(SceneCatalog.cameraOverlayKeys, id: \.self) { key in
                if let p = SceneCatalog.param(for: key) {
                    SceneParamRow(param: p, engine: engine)
                }
            }

            Divider().padding(.vertical, 4)

            Button { engine.runCommand("reset") } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dot.viewfinder")
                    Text("Reset view")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(PanelTheme.selectionTextColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(minWidth: 300, alignment: .leading)
    }
}
```

- [ ] **Step 2: Build macOS.** Expected: BUILD SUCCEEDED (the view compiles even though nothing presents it yet).

- [ ] **Step 3: Build iOS sim.** Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit.**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift
git commit -m "feat(camera-overlay): add shared CameraControlsView"
```

---

### Task 4: `CameraButton` + presentation wiring in `ContentView`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` — add `@State showCameraPanel`; add `cameraButton` view + `.cameraPanelPresentation()` helper; place the button in the macOS (~386) and iOS (~1426) bottom-leading overlays; add a `CameraButton` struct at file scope.

**Interfaces:**
- Consumes: `CameraControlsView`, `PyMOLEngine`, `hSize` (`@Environment(\.horizontalSizeClass)`, ~635).
- Produces: viewport camera chip + popover/sheet.

- [ ] **Step 1: Add state** near the other `@State` panel toggles in the `ContentView` body owner (same scope as `showSettingsSheet` etc.):

```swift
    @State private var showCameraPanel = false
```

- [ ] **Step 2: Add the chip view + presentation modifier** as private helpers on the view:

```swift
    // Bottom-left viewport shortcut to the Camera overlay.
    private var cameraButton: some View {
        Button { showCameraPanel.toggle() } label: {
            Image(systemName: "camera")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(showCameraPanel ? 0.95 : 0.6))
                .frame(width: 46, height: 46)
                .background(.white.opacity(showCameraPanel ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera settings")
    }

    // Popover on regular width (macOS/iPad), bottom sheet on compact (iPhone).
    @ViewBuilder
    private func cameraPanelPresentation<V: View>(_ content: V) -> some View {
        if hSize == .regular {
            content.popover(isPresented: $showCameraPanel, arrowEdge: .bottom) {
                CameraControlsView(engine: engine)
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            content.sheet(isPresented: $showCameraPanel) {
                CameraControlsView(engine: engine)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }
```

- [ ] **Step 3: Place the chip in the macOS bottom-leading overlay** (~386). Replace the existing scene-buttons overlay block so the camera chip is the leftmost item and the scene buttons sit above it (a leading `VStack`), and attach the presentation:

```swift
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 8) {
                                if showSceneButtons && !engine.sceneNames.isEmpty {
                                    sceneButtonsOverlay
                                }
                                if !engine.objects.isEmpty {
                                    cameraPanelPresentation(cameraButton)
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.bottom, 12)
                        }
```

- [ ] **Step 4: Place the chip in the iOS bottom-leading overlay** (~1426). Mirror it, keeping the transport clearance the scene buttons use:

```swift
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if showSceneButtons && !engine.sceneNames.isEmpty {
                        sceneButtonsOverlay
                    }
                    if !engine.objects.isEmpty {
                        cameraPanelPresentation(cameraButton)
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, engine.hasTimeline ? 96 : 12)
            }
```

- [ ] **Step 5: Build macOS.** Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Build iOS sim.** Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit.**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "feat(camera-overlay): add bottom-left camera button + popover/sheet presentation"
```

---

### Task 5: Functional verification (sim + VM)

**Files:** none (verification only).

- [ ] **Step 1: iOS simulator.** Boot a sim, install the iOS build, launch with a structure loaded (e.g. `SIMCTL_CHILD_PYMOL_AUTOCMD="fetch 1ubq, async=0; hide everything; show cartoon; orient"`). Screenshot: confirm the camera chip appears bottom-left.

- [ ] **Step 2:** Tap the chip → confirm a bottom sheet slides up with: Lens, Orthographic, Depth of field, Reset view. Toggle Depth of field on → confirm Auto lock focus / Focus / Aperture / High quality appear. Toggle Orthographic on → confirm the Lens row greys out. Tap Reset view → confirm the camera recenters. Swipe the sheet down → confirm it dismisses. Capture before/after screenshots to the scratchpad.

- [ ] **Step 3: macOS (host or VM).** Launch with a structure; click the chip → confirm a popover anchored at the button shows the same controls; the controls drive the live view; clicking outside dismisses. Confirm the inspector's Scene → Camera group is unchanged (same rows incl. Orthographic + Auto lock focus).

- [ ] **Step 4:** If any check fails, return to the owning task; otherwise the feature is complete.

---

## Self-Review

**Spec coverage:** button placement (Task 4) ✓; popover/sheet by size class (Task 4) ✓; control set Lens/Ortho/DOF+subrows/Reset (Tasks 1+3) ✓; Auto lock focus rename (Task 1) ✓; reuse via SceneParamRow (Task 2) ✓; coexist with scene buttons + transport clearance + empty-scene gating (Task 4) ✓; ortho already polled (noted, no Python change) ✓; range/depth-cue excluded from overlay (Task 1 key list) ✓; no core/.pse/renderer change (Global Constraints) ✓; testing (Task 5) ✓.

**Placeholder scan:** none — every code step has complete code; verification steps name exact checks.

**Type consistency:** `SceneParamRow(param:engine:)` and `CameraControlsView(engine:)` are used identically where produced and consumed; `SceneCatalog.cameraOverlayKeys` / `param(for:)` defined in Task 1 and used in Task 3; `cameraButton` / `cameraPanelPresentation` defined and used in Task 4.
