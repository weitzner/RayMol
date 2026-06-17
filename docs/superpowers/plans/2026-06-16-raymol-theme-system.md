# RayMol Theme / Palette System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user-selectable Theme that controls both app chrome (appearance, accent/bubble/selection/tab colors, terminal font+color, viewport background) and molecular defaults (chain cycle, non-carbon element colors, default style, outline/flat-sheets/fancy-helices), with 3 curated presets + System, custom save/persist, a palette popup opened from a toolbar button, and first-boot auto-present.

**Architecture:** A `ThemeManager: ObservableObject` singleton holds the active `Theme` and the custom list, persists to `UserDefaults` as JSON, and on every change (a) drives SwiftUI chrome via a refactored `PanelTheme` (computed statics resolving `ThemeManager.shared.active`) and `.preferredColorScheme`, and (b) pushes molecular defaults into PyMOL via a new `modules/pymol/raymol_theme.py` module (`set_color` swatches, `bg_color`, `metal_outline`, cartoon settings, default style/rep). New objects get themed at load time through a consolidated `engine.loadStructure`/`fetchStructure` path that calls `raymol_theme.apply_to(obj)`. The agent uses the same themed helpers (`cbc`/`cnc`/`apply_default_style`) exposed in its `run_python` namespace.

**Tech Stack:** SwiftUI (macOS + iOS, branch `swiftui-cross-platform`, NEVER merge to master), embedded CPython 3.13, PyMOL `cmd` API, Metal renderer (`metal_outline` setting).

**Build/verify workflow:**
- macOS: `bash swiftui/build_macos.sh` (only if C/Python core changed) + `xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_xcode build`; launch via `open -nF`, PID-exact screenshot.
- iOS sim: build via existing iOS scheme + `xcrun simctl install/launch`; screenshot via `simctl io screenshot`.
- Theme switches and chrome are pure SwiftUI (no core rebuild needed for C1). C2 touches only Python (`modules/pymol/`), which the app loads from the bundled stdlib — a Python-only change needs the bundle's `modules/pymol` refreshed (the build script copies it) but no C recompile.

---

## File Structure

**New files:**
- `swiftui/PyMOLViewer/Shared/Theme.swift` — `Theme`, `RGBA`, `FontSpec`, `Appearance`, `RepStyle`, the 3 curated presets + System, all `Codable`.
- `swiftui/PyMOLViewer/Shared/ThemeManager.swift` — `ThemeManager: ObservableObject` (active/custom, persistence, select/save/delete, `apply(engine:)`).
- `swiftui/PyMOLViewer/Panels/ThemeSheet.swift` — the palette popup (appearance segmented, preset gallery, custom editor, Save-as-preset).
- `modules/pymol/raymol_theme.py` — engine-side helper (set palette globals, `bg_color`, `metal_outline`, cartoon settings, `apply_to(obj)`, `cbc`/`cnc`/`apply_default_style`).

**Modified files:**
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — `PanelTheme` enum: `static let` → computed `static var` reading `ThemeManager.shared.active`; add `@EnvironmentObject themeManager` to top-level panel views for re-render.
- `swiftui/PyMOLViewer/Panels/CommandPanel.swift` — terminal text color + font + bg from theme.
- `swiftui/PyMOLViewer/Panels/ChatPanel.swift` — bubble + accent from theme.
- `swiftui/PyMOLViewer/Panels/MousePanel.swift`, `SequencePanel.swift` — route hardcoded chrome colors through `PanelTheme`.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` — palette toolbar button (both platforms), `.sheet`/`.popover` for ThemeSheet, `.preferredColorScheme(themeManager.active.appearance.colorScheme)`, `.tint(themeManager.active.tabTint.color)`, route load sites through `engine.loadStructure`.
- `swiftui/PyMOLViewer/Shared/PyMOLApp.swift` — inject `.environmentObject(ThemeManager.shared)`; first-boot flag; route `loadOpenedFile` through `engine.loadStructure`.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `loadStructure(path:name:)` / `fetchStructure(id:)` wrappers that load then call `raymol_theme.apply_to`; `applyTheme(...)` helper that pushes the palette to `raymol_theme`.
- `modules/pymol/ai_system_prompt.py`, `modules/pymol/ai_tools.py` — expose `cbc`/`cnc`/`apply_default_style` in the run_python namespace + instruct the agent to use them.

---

## Phase C0 — Theme model + ThemeManager (no UI yet)

### Task 1: Theme model and presets

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/Theme.swift`

- [ ] **Step 1: Write `Theme.swift`**

```swift
// Theme.swift — RayMol theme model: app chrome + molecular defaults.
// A Theme is fully Codable so custom themes persist as JSON in UserDefaults.

import SwiftUI

/// sRGB color, Codable (SwiftUI.Color is not Codable).
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    /// "r g b" in 0..1 for PyMOL set_color.
    var pymolTriplet: String { String(format: "%.4f, %.4f, %.4f", r, g, b) }
}

struct FontSpec: Codable, Equatable {
    enum Family: String, Codable, CaseIterable { case monospaced, system, serif, rounded }
    var family: Family
    var size: Double
    var design: Font.Design {
        switch family {
        case .monospaced: return .monospaced
        case .serif:      return .serif
        case .rounded:    return .rounded
        case .system:     return .default
        }
    }
    var font: Font { .system(size: size, design: design) }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// nil = follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

enum RepStyle: String, Codable, CaseIterable, Identifiable {
    case cartoon, sticks, ballStick = "ball_stick", spheres, surface, pretty
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ballStick: return "Ball & Stick"
        default: return rawValue.capitalized
        }
    }
}

struct Theme: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var builtIn: Bool
    var appearance: Appearance

    // App chrome
    var accent: RGBA
    var bubble: RGBA
    var selectionName: RGBA
    var tabTint: RGBA
    var viewportBackground: RGBA
    var terminalFont: FontSpec
    var terminalText: RGBA
    var panelBackground: RGBA   // chrome surface (panels, console bg)
    var panelText: RGBA

    // Molecular defaults (NEW objects only)
    var chainCycle: [RGBA]
    var elementColors: [String: RGBA]   // N,O,S,P,H,halogens… (carbon untouched)
    var defaultStyle: RepStyle

    // Render toggles
    var outline: Bool
    var flatSheets: Bool
    var fancyHelices: Bool
}
```

- [ ] **Step 2: Add the 3 curated presets + System to `Theme.swift`**

```swift
extension Theme {
    // Stable IDs so persistence (active-id) survives relaunch.
    static let midnightID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let paperID    = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let terminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let systemID   = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    /// PyMOL-default-ish chain cycle (matches util.color_chains spectrum-ish).
    static let defaultChainCycle: [RGBA] = [
        RGBA(0.25, 0.55, 1.00), RGBA(0.20, 0.80, 0.40), RGBA(1.00, 0.50, 0.20),
        RGBA(0.85, 0.30, 0.85), RGBA(0.95, 0.85, 0.25), RGBA(0.30, 0.85, 0.85),
        RGBA(1.00, 0.40, 0.40), RGBA(0.60, 0.45, 0.95)
    ]
    /// PyMOL element colors (non-carbon). Carbon is intentionally absent.
    static let defaultElementColors: [String: RGBA] = [
        "N": RGBA(0.20, 0.20, 1.00), "O": RGBA(1.00, 0.20, 0.20),
        "S": RGBA(0.90, 0.78, 0.20), "P": RGBA(1.00, 0.50, 0.00),
        "H": RGBA(0.90, 0.90, 0.90), "F": RGBA(0.50, 0.85, 0.25),
        "CL": RGBA(0.30, 0.85, 0.25), "BR": RGBA(0.60, 0.32, 0.12),
        "I": RGBA(0.58, 0.00, 0.58)
    ]

    static let midnight = Theme(
        id: midnightID, name: "Midnight", builtIn: true, appearance: .dark,
        accent: RGBA(0.29, 0.565, 0.851), bubble: RGBA(0.29, 0.565, 0.851),
        selectionName: RGBA(0.30, 1.00, 1.00), tabTint: RGBA(0.29, 0.565, 0.851),
        viewportBackground: RGBA(0.0, 0.0, 0.0),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(0.0, 1.0, 0.0),
        panelBackground: RGBA(0.15, 0.15, 0.17), panelText: RGBA(0.85, 0.85, 0.85),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: false, flatSheets: false, fancyHelices: false)

    static let paper = Theme(
        id: paperID, name: "Paper", builtIn: true, appearance: .light,
        accent: RGBA(0.10, 0.45, 0.85), bubble: RGBA(0.10, 0.45, 0.85),
        selectionName: RGBA(0.85, 0.35, 0.0), tabTint: RGBA(0.10, 0.45, 0.85),
        viewportBackground: RGBA(1.0, 1.0, 1.0),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(0.10, 0.10, 0.10),
        panelBackground: RGBA(0.95, 0.95, 0.96), panelText: RGBA(0.12, 0.12, 0.14),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: true, flatSheets: true, fancyHelices: false)

    static let terminal = Theme(
        id: terminalID, name: "Terminal", builtIn: true, appearance: .dark,
        accent: RGBA(0.20, 0.90, 0.40), bubble: RGBA(0.10, 0.40, 0.15),
        selectionName: RGBA(0.20, 0.90, 0.40), tabTint: RGBA(0.20, 0.90, 0.40),
        viewportBackground: RGBA(0.0, 0.05, 0.0),
        terminalFont: FontSpec(family: .monospaced, size: 12), terminalText: RGBA(0.20, 1.0, 0.30),
        panelBackground: RGBA(0.04, 0.07, 0.04), panelText: RGBA(0.20, 0.90, 0.40),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .sticks, outline: false, flatSheets: false, fancyHelices: false)

    /// System = Midnight chrome but appearance follows the OS.
    static var system: Theme {
        var t = midnight
        t.id = systemID; t.name = "System"; t.appearance = .system
        return t
    }

    static let builtInPresets: [Theme] = [midnight, paper, terminal, system]
}
```

- [ ] **Step 3: Build to verify it compiles** (run after Task 2 wires the manager; for now just save). No standalone test — Swift model.

### Task 2: ThemeManager

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/ThemeManager.swift`

- [ ] **Step 1: Write `ThemeManager.swift`**

```swift
// ThemeManager.swift — owns the active theme + custom list; persists to UserDefaults;
// pushes molecular/viewport defaults into PyMOL via raymol_theme.

import SwiftUI

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var active: Theme
    @Published private(set) var custom: [Theme]

    /// True until the user picks a theme for the first time (drives first-boot popup).
    @Published var firstBoot: Bool

    private let activeKey = "raymol.theme.activeID"
    private let customKey = "raymol.theme.custom"
    private let firstBootKey = "raymol.theme.didFirstBoot"

    var presets: [Theme] { Theme.builtInPresets }
    var all: [Theme] { presets + custom }

    private init() {
        let d = UserDefaults.standard
        // Load custom list.
        if let data = d.data(forKey: customKey),
           let decoded = try? JSONDecoder().decode([Theme].self, from: data) {
            custom = decoded
        } else {
            custom = []
        }
        // Resolve active by stored id (preset or custom), default Midnight.
        let storedID = d.string(forKey: activeKey).flatMap { UUID(uuidString: $0) }
        let pool = Theme.builtInPresets + custom
        active = pool.first(where: { $0.id == storedID }) ?? Theme.midnight
        firstBoot = d.object(forKey: firstBootKey) == nil
    }

    // MARK: - Selection / editing

    func select(_ theme: Theme, engine: PyMOLEngine? = nil) {
        active = theme
        persistActive()
        if let engine { apply(engine: engine) }
    }

    /// Save (or overwrite by name) a custom theme and make it active.
    func saveCustom(_ theme: Theme, engine: PyMOLEngine? = nil) {
        var t = theme
        t.builtIn = false
        if t.id == Theme.midnightID || t.id == Theme.paperID
            || t.id == Theme.terminalID || t.id == Theme.systemID {
            t.id = UUID()   // never overwrite a preset id
        }
        if let i = custom.firstIndex(where: { $0.id == t.id }) {
            custom[i] = t
        } else {
            custom.append(t)
        }
        persistCustom()
        select(t, engine: engine)
    }

    func deleteCustom(_ theme: Theme) {
        custom.removeAll { $0.id == theme.id }
        persistCustom()
        if active.id == theme.id { active = Theme.midnight; persistActive() }
    }

    func markFirstBootDone() {
        firstBoot = false
        UserDefaults.standard.set(true, forKey: firstBootKey)
    }

    // MARK: - Apply to PyMOL

    /// Push viewport bg + render toggles + molecular default palette into PyMOL.
    /// Chrome (SwiftUI) updates automatically via @Published `active`.
    func apply(engine: PyMOLEngine) {
        engine.applyTheme(active)
    }

    // MARK: - Persistence

    private func persistActive() {
        UserDefaults.standard.set(active.id.uuidString, forKey: activeKey)
    }
    private func persistCustom() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }
}
```

- [ ] **Step 2: Add `applyTheme` + `loadStructure`/`fetchStructure` to `PyMOLEngine.swift`** (see Task 9 for the molecular detail; here add the chrome-immediate + bg portion so C0 compiles). Insert near `runPython` (PyMOLEngine.swift ~line 572):

```swift
// MARK: - Theme

/// Push a theme's molecular/viewport defaults into PyMOL. Chrome is handled
/// in SwiftUI; this covers bg_color + render toggles + the default palette
/// that NEW objects pick up via raymol_theme.apply_to.
func applyTheme(_ theme: Theme) {
    guard isReady else { return }
    var py = "from pymol import raymol_theme as _rt\n"
    py += "_rt.set_palette(\n"
    py += "  bg=(\(theme.viewportBackground.pymolTriplet)),\n"
    py += "  outline=\(theme.outline ? "True" : "False"),\n"
    py += "  flat_sheets=\(theme.flatSheets ? "True" : "False"),\n"
    py += "  fancy_helices=\(theme.fancyHelices ? "True" : "False"),\n"
    py += "  default_style='\(theme.defaultStyle.rawValue)',\n"
    py += "  chain_cycle=[\(theme.chainCycle.map { "(\($0.pymolTriplet))" }.joined(separator: ", "))],\n"
    let elems = theme.elementColors.map { "'\($0.key)': (\($0.value.pymolTriplet))" }.joined(separator: ", ")
    py += "  element_colors={\(elems)},\n"
    py += ")\n"
    runPython(py)
}
```

- [ ] **Step 3: Build macOS** to confirm C0 compiles (model + manager + engine hook). The `raymol_theme` import will no-op-fail gracefully until Task 8 creates it — guard `applyTheme` is only called after Task 8. Expected: clean build.

```bash
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_xcode build 2>&1 | tail -5
```

- [ ] **Step 4: Commit C0**

```bash
git add swiftui/PyMOLViewer/Shared/Theme.swift swiftui/PyMOLViewer/Shared/ThemeManager.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(theme): C0 — Theme model + ThemeManager + engine applyTheme hook"
```

---

## Phase C1 — App chrome (SwiftUI)

### Task 3: PanelTheme reads the active theme

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift:486-495`

- [ ] **Step 1: Convert `PanelTheme` statics to computed properties**

```swift
private enum PanelTheme {
    private static var t: Theme { ThemeManager.shared.active }
    static var background: Color { t.panelBackground.color }
    static var rowBackground: Color { t.panelBackground.color.opacity(0.92) }
    static var rowAltBackground: Color { t.panelBackground.color.opacity(0.82) }
    static var textColor: Color { t.panelText.color }
    static var selectionTextColor: Color { t.selectionName.color }
    static var buttonBackground: Color { t.accent.color.opacity(0.22) }
    static var buttonText: Color { t.panelText.color }
    static var headerColor: Color { t.panelText.color.opacity(0.7) }
    static var disabledColor: Color { t.panelText.color.opacity(0.5) }
}
```

- [ ] **Step 2: Make the top-level panel views observe ThemeManager so they re-render on switch.** Add `@EnvironmentObject private var themeManager: ThemeManager` to each top-level panel `struct` (ObjectPanel, and in their files: ChatPanel, CommandPanel, SequencePanel, MousePanel). For ObjectPanel, add near its other `@EnvironmentObject`/`@State` declarations.

- [ ] **Step 3: Build + screenshot macOS** — confirm Objects panel still renders identically under the default (Midnight) theme. Expected: visually unchanged.

### Task 4: Route remaining hardcoded chrome colors through the theme

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/CommandPanel.swift:16-19,85-98`
- Modify: `swiftui/PyMOLViewer/Panels/ChatPanel.swift:152-154,600-602`
- Modify: `swiftui/PyMOLViewer/Panels/MousePanel.swift`, `SequencePanel.swift`

- [ ] **Step 1: CommandPanel — terminal text/font/bg from theme.** Replace the hardcoded constants with theme reads. Add `@EnvironmentObject private var themeManager: ThemeManager`, then:

```swift
private var theme: Theme { themeManager.active }
// log text color  -> theme.terminalText.color
// prompt color    -> theme.terminalText.color
// console bg       -> theme.panelBackground.color
// log font         -> theme.terminalFont.font (replace .font(.system(size: 11, design: .monospaced)))
```
For the `LogView` subview (which currently takes `textColor: Color`), also pass `font: Font` and `bg: Color` from the parent's `theme`. For the macOS `NSTextField` input, set `field.textColor = NSColor(theme.terminalText.color)` and `field.font = .monospacedSystemFont(ofSize: CGFloat(theme.terminalFont.size), weight: .regular)` in `updateNSView` (so it re-applies on theme change).

- [ ] **Step 2: ChatPanel — bubble + accent from theme.** Add `@EnvironmentObject private var themeManager`. Replace `accentBlue` usages with `themeManager.active.accent.color` and `userBubbleColor` with `themeManager.active.bubble.color`. For the `MessageBubbleView` subview, pass the bubble color in via an initializer parameter (it's a separate struct without environment access, or add `@EnvironmentObject` to it too).

- [ ] **Step 3: MousePanel + SequencePanel — selection/header colors from PanelTheme.** Replace the cyan selection color (MousePanel ~434) with `PanelTheme.selectionTextColor`; replace SequencePanel header/ruler/bg (54-56) with `PanelTheme.textColor`/`PanelTheme.headerColor`/`PanelTheme.background`. Add `@EnvironmentObject private var themeManager` to both so they re-render.

- [ ] **Step 4: Build + screenshot macOS** under Midnight — confirm console green-on-black, chat blue bubble, cyan selection all unchanged.

### Task 5: Appearance + tab tint at the root

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift:436` (and the iOS root)
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLApp.swift:44-67`

- [ ] **Step 1: Inject ThemeManager in PyMOLApp** — `ContentView().environmentObject(engine).environmentObject(engine.playback).environmentObject(ThemeManager.shared)`.

- [ ] **Step 2: ContentView root — appearance + tint.** Add `@EnvironmentObject private var themeManager: ThemeManager`. Replace the hardcoded `.preferredColorScheme(.dark)` (line 436) with `.preferredColorScheme(themeManager.active.appearance.colorScheme)`. On the iOS `TabView`/`NavigationStack` and macOS chrome, add `.tint(themeManager.active.tabTint.color)`.

- [ ] **Step 3: Build + screenshot** — switch nothing yet (no UI). Confirm Midnight still dark. (Light/Terminal verified after Task 6 ships the picker.)

### Task 6: ThemeSheet (the palette popup) + toolbar button + first boot

**Files:**
- Create: `swiftui/PyMOLViewer/Panels/ThemeSheet.swift`
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (toolbar button + `.sheet`)

- [ ] **Step 1: Write `ThemeSheet.swift`** — appearance segmented control, preset+custom swatch gallery (tap = `select` live), a disclosure "Customize" editor with `ColorPicker` wells for accent/bubble/selectionName/tabTint/viewportBackground/terminalText + a font family Picker + size Stepper + default-style Picker + the three Toggles (outline/flatSheets/fancyHelices), and a "Save as preset" button (prompts for a name → `saveCustom`). Bind to `@EnvironmentObject var themeManager` and `@EnvironmentObject var engine`. On every edit, build a working `Theme` and call `themeManager.select(working, engine: engine)` so changes are live; "Save as preset" calls `themeManager.saveCustom(working, engine: engine)`.

```swift
// ThemeSheet.swift — RayMol palette popup. Live-applies on edit; saves customs.
import SwiftUI

struct ThemeSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss

    @State private var working: Theme = ThemeManager.shared.active
    @State private var showCustomize = false
    @State private var saveName = ""
    @State private var showSavePrompt = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { working.appearance },
                        set: { working.appearance = $0; live() })) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Presets") { presetGallery }
                Section {
                    DisclosureGroup("Customize", isExpanded: $showCustomize) { editor }
                }
                if !themeManager.custom.isEmpty {
                    Section("My Themes") { customGallery }
                }
            }
            .navigationTitle("Theme")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save as Preset") { saveName = ""; showSavePrompt = true }
                }
            }
            .alert("Name your theme", isPresented: $showSavePrompt) {
                TextField("Theme name", text: $saveName)
                Button("Save") {
                    var t = working; t.name = saveName.isEmpty ? "Custom" : saveName
                    t.builtIn = false; t.id = UUID()
                    themeManager.saveCustom(t, engine: engine)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { working = themeManager.active }
    }

    private func live() { themeManager.select(working, engine: engine) }

    private var presetGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(themeManager.presets) { t in swatch(t) }
            }.padding(.vertical, 4)
        }
    }
    private var customGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(themeManager.custom) { t in
                    swatch(t).contextMenu { Button("Delete", role: .destructive) { themeManager.deleteCustom(t) } }
                }
            }.padding(.vertical, 4)
        }
    }
    private func swatch(_ t: Theme) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(t.viewportBackground.color)
                HStack(spacing: 3) {
                    Circle().fill(t.accent.color).frame(width: 12, height: 12)
                    Circle().fill(t.selectionName.color).frame(width: 12, height: 12)
                    Circle().fill(t.terminalText.color).frame(width: 12, height: 12)
                }
            }
            .frame(width: 64, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(themeManager.active.id == t.id ? Color.accentColor : .clear, lineWidth: 2))
            Text(t.name).font(.caption2)
        }
        .onTapGesture { working = t; themeManager.select(t, engine: engine) }
    }

    @ViewBuilder private var editor: some View {
        ColorPicker("Accent", selection: bind(\.accent))
        ColorPicker("Chat bubble", selection: bind(\.bubble))
        ColorPicker("Selection name", selection: bind(\.selectionName))
        ColorPicker("Tab tint", selection: bind(\.tabTint))
        ColorPicker("Viewport background", selection: bind(\.viewportBackground))
        ColorPicker("Terminal text", selection: bind(\.terminalText))
        Picker("Terminal font", selection: Binding(
            get: { working.terminalFont.family },
            set: { working.terminalFont.family = $0; live() })) {
            ForEach(FontSpec.Family.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Stepper("Font size \(Int(working.terminalFont.size))", value: Binding(
            get: { working.terminalFont.size },
            set: { working.terminalFont.size = $0; live() }), in: 8...20)
        Picker("Default style", selection: Binding(
            get: { working.defaultStyle },
            set: { working.defaultStyle = $0; live() })) {
            ForEach(RepStyle.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Outline", isOn: boolBind(\.outline))
        Toggle("Cartoon flat sheets", isOn: boolBind(\.flatSheets))
        Toggle("Fancy helices", isOn: boolBind(\.fancyHelices))
    }

    private func bind(_ kp: WritableKeyPath<Theme, RGBA>) -> Binding<Color> {
        Binding(get: { working[keyPath: kp].color },
                set: { working[keyPath: kp] = $0.rgba; live() })
    }
    private func boolBind(_ kp: WritableKeyPath<Theme, Bool>) -> Binding<Bool> {
        Binding(get: { working[keyPath: kp] },
                set: { working[keyPath: kp] = $0; live() })
    }
}

// Color -> RGBA (resolve in sRGB).
extension Color {
    var rgba: RGBA {
        #if os(macOS)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}
```

- [ ] **Step 2: Add the palette toolbar button + sheet to ContentView.** Add `@State private var showThemeSheet = false`. In the macOS `.toolbar` (line ~199) add before `exportMenu`:

```swift
ToolbarItem {
    Button { showThemeSheet = true } label: { Label("Theme", systemImage: "paintpalette.fill") }
        .help("Theme & palette")
}
```
For iOS, add a palette `ToolbarItem(placement: .primaryAction)` (next to the pane-popover button) with the same `Image(systemName: "paintpalette.fill")` action. Attach `.sheet(isPresented: $showThemeSheet) { ThemeSheet().environmentObject(themeManager).environmentObject(engine) }` to the root (alongside the existing Settings sheet).

- [ ] **Step 3: First-boot auto-present.** In ContentView's root `.onAppear` (where engine init runs), after engine is ready: `if themeManager.firstBoot { showThemeSheet = true; themeManager.markFirstBootDone() }`.

- [ ] **Step 4: Build + screenshot macOS** — open the palette, tap **Paper**: confirm the window goes light, viewport white, console dark-on-light; tap **Terminal**: green mono everything; tap **Midnight**: back to dark. Capture all three.

- [ ] **Step 5: Build + screenshot iOS sim** — same three-preset switch on the simulator.

- [ ] **Step 6: Commit C1**

```bash
git add swiftui/PyMOLViewer/Panels/ThemeSheet.swift swiftui/PyMOLViewer/Panels/ObjectPanel.swift swiftui/PyMOLViewer/Panels/CommandPanel.swift swiftui/PyMOLViewer/Panels/ChatPanel.swift swiftui/PyMOLViewer/Panels/MousePanel.swift swiftui/PyMOLViewer/Panels/SequencePanel.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Shared/PyMOLApp.swift
git commit -m "feat(theme): C1 — themed chrome (PanelTheme/console/chat), palette popup, appearance, first-boot"
```

**CHECKPOINT after C1** — present screenshots of all 3 presets on both platforms before starting C2.

---

## Phase C2 — Molecular defaults + agent

### Task 7: `raymol_theme.py` engine helper

**Files:**
- Create: `modules/pymol/raymol_theme.py`

- [ ] **Step 1: Write `raymol_theme.py`**

```python
"""RayMol theme engine helper.

Holds the active palette (chain cycle + non-carbon element colors + default
style + render toggles), applies the immediate scene-wide bits (bg_color,
metal_outline), and themes NEW objects at load time via apply_to(). Existing
objects are never restyled/recolored on a theme change.
"""
from pymol import cmd

# Active palette globals (defaults match the SwiftUI Midnight preset).
_chain_cycle = []          # list of (r,g,b)
_element_colors = {}       # {"N": (r,g,b), ...}  (carbon intentionally absent)
_default_style = "cartoon"
_flat_sheets = False
_fancy_helices = False

_CHAIN_PREFIX = "raymol_chain_"
_ELEM_PREFIX = "raymol_elem_"


def set_palette(bg=None, outline=False, flat_sheets=False, fancy_helices=False,
                default_style="cartoon", chain_cycle=None, element_colors=None):
    """Store the active palette and apply the immediate scene-wide settings.

    Called by Swift (PyMOLEngine.applyTheme) on every theme change. Defines
    named colors for the chain cycle and non-carbon elements so apply_to() can
    reference them. Does NOT touch existing objects.
    """
    global _chain_cycle, _element_colors, _default_style, _flat_sheets, _fancy_helices
    _default_style = default_style or "cartoon"
    _flat_sheets = bool(flat_sheets)
    _fancy_helices = bool(fancy_helices)

    if bg is not None:
        cmd.bg_color("0x%02x%02x%02x" % (int(bg[0] * 255), int(bg[1] * 255), int(bg[2] * 255)))
    cmd.set("metal_outline", 1 if outline else 0)

    _chain_cycle = list(chain_cycle or [])
    for i, rgb in enumerate(_chain_cycle):
        cmd.set_color("%s%d" % (_CHAIN_PREFIX, i), list(rgb))

    _element_colors = dict(element_colors or {})
    for elem, rgb in _element_colors.items():
        cmd.set_color("%s%s" % (_ELEM_PREFIX, elem.upper()), list(rgb))


def cbc(selection="(all)"):
    """Color by chain using the active palette's chain cycle.

    Cycles raymol_chain_<i> over the chains present in `selection`. Falls back
    to PyMOL's util.cbc when no palette is set.
    """
    if not _chain_cycle:
        from pymol import util
        util.cbc(selection=selection)
        return
    chains = cmd.get_chains(selection)
    for i, ch in enumerate(chains):
        color = "%s%d" % (_CHAIN_PREFIX, i % len(_chain_cycle))
        sel = "(%s) and chain %s" % (selection, ch) if ch else "(%s)" % selection
        cmd.color(color, sel)


def cnc(selection="(all)"):
    """Color non-carbon atoms by the active element palette; carbon untouched."""
    if not _element_colors:
        from pymol import util
        util.cnc(selection=selection)
        return
    for elem, _ in _element_colors.items():
        cmd.color("%s%s" % (_ELEM_PREFIX, elem.upper()),
                  "(%s) and elem %s" % (selection, elem))


def apply_default_style(obj):
    """Apply the active default representation + cartoon settings to `obj`."""
    style = _default_style
    cmd.set("cartoon_flat_sheets", 1 if _flat_sheets else 0, obj)
    cmd.set("cartoon_fancy_helices", 1 if _fancy_helices else 0, obj)
    if style == "cartoon":
        cmd.hide("everything", obj); cmd.show("cartoon", obj)
    elif style == "sticks":
        cmd.hide("everything", obj); cmd.show("sticks", obj)
    elif style == "spheres":
        cmd.hide("everything", obj); cmd.show("spheres", obj)
    elif style == "ball_stick":
        cmd.hide("everything", obj); cmd.show("sticks", obj); cmd.show("spheres", obj)
        cmd.set("sphere_scale", 0.25, obj); cmd.set("stick_radius", 0.14, obj)
    elif style == "surface":
        cmd.show("surface", obj)
    elif style == "pretty":
        cmd.hide("everything", obj); cmd.show("cartoon", obj)


def apply_to(obj):
    """Theme a NEWLY loaded object: default style + themed chain/element colors."""
    try:
        apply_default_style(obj)
        cbc("(%s)" % obj)
        cnc("(%s)" % obj)
    except Exception as e:
        print("raymol_theme.apply_to(%r) failed: %s" % (obj, e))
```

- [ ] **Step 2: Smoke-test in headless PyMOL** (no GUI):

```bash
PYMOL_METAL_ONLY= python3 -c "import pymol; pymol.finish_launching(['pymol','-cq']); from pymol import cmd, raymol_theme as rt; rt.set_palette(bg=(0,0,0), default_style='cartoon', chain_cycle=[(0.25,0.55,1.0)], element_colors={'N':(0.2,0.2,1.0)}); cmd.fetch('1ubq', async_=0, type='pdb') if False else cmd.load('1ubq.cif'); rt.apply_to('1ubq'); print('OK', cmd.get_names())"
```
Expected: `OK ['1ubq']` with no traceback. (Uses the repo-root `1ubq.cif` already present.)

- [ ] **Step 3: Commit**

```bash
git add modules/pymol/raymol_theme.py
git commit -m "feat(theme): C2a — raymol_theme.py (set_palette/cbc/cnc/apply_default_style/apply_to)"
```

### Task 8: New-object load hook (consolidate load sites)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (5 load sites), `PyMOLApp.swift` (loadOpenedFile)

- [ ] **Step 1: Add `loadStructure`/`fetchStructure` to PyMOLEngine** (near runCommand):

```swift
/// Load a structure then theme it (default style + chain/element colors) for
/// the NEW object only. Routes all UI/agent/open-with load paths.
func loadStructure(path: String, name: String) {
    guard isReady else { return }
    runCommand("load \(path), \(name)")
    runPython("from pymol import raymol_theme as _rt; _rt.apply_to('\(name)')")
}

func fetchStructure(id: String) {
    guard isReady else { return }
    let clean = id.replacingOccurrences(of: "'", with: "")
    runCommand("fetch \(clean), async=0, type=pdb")
    runPython("from pymol import raymol_theme as _rt; _rt.apply_to('\(clean)')")
}
```

- [ ] **Step 2: Route the 5 load sites.**
  - ContentView `macOpenFile()` (~253): `engine.runCommand("load ...")` → `engine.loadStructure(path: url.path, name: name)`.
  - ContentView `macFetch()` (~258): → `engine.fetchStructure(id: id)`.
  - ContentView `iosHandleImport` (~937): → `engine.loadStructure(path: safe.path, name: name)`.
  - ContentView `iosFetch()` (~898): → `engine.fetchStructure(id: id)`.
  - PyMOLApp `loadOpenedFile` (~123): → `engine.loadStructure(path: path, name: name)`.

- [ ] **Step 3: Build + screenshot** — under **Paper** theme, Open `1ubq.cif`: confirm the NEW object loads as cartoon with the themed chain color and white bg. Switch to Midnight (existing object should NOT recolor) then load `2kpo.cif`: confirm only the new one picks up Midnight defaults.

- [ ] **Step 4: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Shared/PyMOLApp.swift
git commit -m "feat(theme): C2b — theme NEW objects at load via loadStructure/fetchStructure hook"
```

### Task 9: Agent adheres to theme defaults

**Files:**
- Modify: `modules/pymol/ai_tools.py` (run_python namespace)
- Modify: `modules/pymol/ai_system_prompt.py`

- [ ] **Step 1: Expose themed helpers in the run_python namespace.** In `ai_tools.py` where `_py_namespace` is seeded (cmd/np/Bio/WORKDIR), add `raymol_theme` and convenience bindings:

```python
from pymol import raymol_theme
_py_namespace.setdefault("raymol_theme", raymol_theme)
_py_namespace.setdefault("cbc", raymol_theme.cbc)
_py_namespace.setdefault("cnc", raymol_theme.cnc)
_py_namespace.setdefault("apply_default_style", raymol_theme.apply_default_style)
```

- [ ] **Step 2: Instruct the agent (system prompt).** In `ai_system_prompt.py` add a short section:

```
Theme consistency: the app has an active visual theme. When you create or
color objects, use the themed helpers so results match the user's palette:
- color by chain  -> call cbc('<sel>')  (NOT util.cbc / spectrum)
- color non-carbon by element -> call cnc('<sel>')
- apply the user's default representation -> apply_default_style('<obj>')
After loading a structure with cmd.load/cmd.fetch, call
raymol_theme.apply_to('<obj>') so it adopts the theme defaults.
```

- [ ] **Step 3: Smoke-test** the namespace import headless:

```bash
python3 -c "from pymol import ai_tools; print('cbc' in dir(ai_tools) or hasattr(__import__('pymol.raymol_theme', fromlist=['cbc']),'cbc'))"
```
Expected: `True`.

- [ ] **Step 4: Build the app bundle's python** (refresh bundled `modules/pymol`) and **screenshot**: ask Raymond "color this by chain" and confirm it uses the palette's chain cycle (matches the swatch). If `build_macos.sh` is needed to refresh the bundled stdlib, run it; otherwise the dev bundle reads `modules/pymol` directly.

- [ ] **Step 5: Commit C2**

```bash
git add modules/pymol/ai_tools.py modules/pymol/ai_system_prompt.py
git commit -m "feat(theme): C2c — agent uses themed cbc/cnc/apply_default_style + apply_to"
```

---

## Phase C3 — Open/Save verification (already implemented)

### Task 10: Verify Open/Save buttons are visible + wired

**Files:** none expected (verification only).

- [ ] **Step 1:** Confirm macOS Open is reachable (the import/fetch menu `onOpen: { macOpenFile() }`, ContentView ~224) and Save Session is in the export menu (~1172). If macOS lacks a *visible* top-level Open affordance, add a toolbar `Button { macOpenFile() } label: { Label("Open", systemImage: "folder") }`.
- [ ] **Step 2:** Confirm iOS Open folder button (~915) + Share Session (~998) appear. Screenshot both platforms' toolbars.
- [ ] **Step 3:** If anything was added, commit `fix(io): expose Open button on macOS toolbar`.

---

## Self-Review

- **Spec coverage:** appearance (Task 5) ✓; accent/bubble/selectionName/tabTint (Tasks 3-5) ✓; terminalFont/terminalText (Task 4) ✓; viewportBackground (Task 2 applyTheme `bg_color`) ✓; chainCycle/elementColors on NEW objects (Tasks 7-8) ✓; defaultStyle on NEW objects (Tasks 7-8) ✓; outline immediate (Task 7 `metal_outline`) ✓; flatSheets/fancyHelices on NEW cartoon (Task 7) ✓; 3 presets + System + custom save/persist (Tasks 1-2, 6) ✓; palette toolbar button + popup + first-boot (Task 6) ✓; agent adherence (Task 9) ✓; Open/Save (Task 10) ✓.
- **Type consistency:** `RGBA.color`/`.pymolTriplet`, `FontSpec.font`, `Appearance.colorScheme`, `RepStyle.rawValue` used consistently across Swift; `Color.rgba` defined in ThemeSheet (move to Theme.swift if referenced earlier — it's only used in ThemeSheet). `ThemeManager.shared.active` is the single source for `PanelTheme`. `set_palette`/`apply_to`/`cbc`/`cnc`/`apply_default_style` names match between `raymol_theme.py`, `PyMOLEngine.applyTheme`, and `ai_tools.py`.
- **Decision: outline scope.** Spec says outline is scene-wide/immediate → applied in `set_palette` via `metal_outline` (not per-object). flatSheets/fancyHelices are cartoon settings applied per NEW object in `apply_default_style`. Consistent with the application-points table.
- **Risk note:** `PanelTheme` re-render relies on each top-level panel observing `ThemeManager`. Tasks 3-5 add `@EnvironmentObject themeManager` to every panel that reads `PanelTheme`; sheets get the manager passed explicitly. If a panel fails to re-skin on switch, it's missing that observer — the fix is one line.
