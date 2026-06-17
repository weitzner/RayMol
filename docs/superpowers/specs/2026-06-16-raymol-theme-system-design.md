# RayMol Theme / Palette System — Design

**Goal:** A user-selectable **Theme** that controls both the app chrome and the molecular defaults. Ships with 3 curated presets, the user can create and save custom presets, and the active theme is applied on every launch (with the theme popup shown automatically on first boot).

Branch: `swiftui-cross-platform` (never merge to master). Implement **after** workstreams A and B merge — C's `PanelTheme` refactor and engine hooks touch files A/B are editing (`ChatPanel.swift`, `ObjectPanel.swift`, `ai_chat.py`/`ai_tools.py`).

## Locked decisions
1. **Presets + custom:** 3 curated built-in presets + System; the user can fully edit colors/font/style and **save custom presets**. Custom presets persist across launches.
2. **Scope of molecular defaults:** the default **style** and the molecular **color defaults** (chain cycle, non-carbon element colors) apply to **NEW objects only**, applied at load time. Changing the theme does **not** restyle or recolor existing objects. The **viewport background** and all **app chrome** change immediately on theme switch.
3. **Agent adheres to defaults:** Raymond uses the active theme's defaults for consistency — themed `cbc`/`cnc` + default-style helpers are exposed in the `run_python` namespace, and the system prompt instructs the agent to use them (e.g., "color by chain" uses the palette's chain cycle).
4. **Entry point + first boot:** a dedicated **palette button** in the top toolbar opens the theme **popup** (both platforms). On **first app boot** the popup auto-presents (first-run theming). The active theme is persisted and re-applied on every launch.

## Model
```swift
enum Appearance: String, Codable { case dark, light, system }
enum RepStyle: String, Codable { case cartoon, ballStick, surface, sticks, pretty }

struct Theme: Codable, Identifiable {
    var id: UUID
    var name: String
    var builtIn: Bool            // curated (read-only) vs user-saved
    var appearance: Appearance

    // App chrome
    var accent: RGBA             // buttons
    var bubble: RGBA            // chat user bubble
    var selectionName: RGBA      // selection labels (cyan today)
    var tabTint: RGBA            // tab-bar icons (Abc/cube/folder/Raymond)
    var viewportBackground: RGBA // 3D bg
    var terminalFont: FontSpec   // family + size
    var terminalText: RGBA       // console text (green today)

    // Molecular defaults (applied to NEW objects)
    var chainCycle: [RGBA]       // per-chain color cycle
    var elementColors: [String: RGBA] // N,O,S,P,H,halogens… (carbon untouched)
    var defaultStyle: RepStyle

    // Render defaults (toggles)
    var outline: Bool            // silhouette/toon outline post-pass (scene-wide, immediate)
    var flatSheets: Bool         // cartoon_flat_sheets
    var fancyHelices: Bool       // cartoon_fancy_helices
}
```
`RGBA`/`FontSpec` are small Codable structs. Themes (active id + custom list) persist as JSON in `UserDefaults`.

## Components
- **`ThemeManager: ObservableObject`** — `@Published active: Theme`, `presets: [Theme]` (3 curated + System), `custom: [Theme]`; load/save to UserDefaults; `select(_:)`, `saveCustom(_:)`, `deleteCustom(_:)`; `apply(engine:)` pushes molecular/viewport defaults to PyMOL.
- **`PanelTheme` refactor** — today it's static hardcoded colors in `ObjectPanel.swift`, referenced everywhere. Make it read from `ThemeManager.active` (inject the manager via `@EnvironmentObject`, or have `PanelTheme` resolve from a shared `ThemeManager.shared`). This single refactor re-skins buttons, bubbles, selection names, backgrounds, tab tint.
- **`ThemeSheet` (the popup)** — appearance segmented (Dark/Light/System); a swatch gallery of presets + saved customs (tap = apply live); a **custom editor** (color wells per chrome+molecular target, font picker, default-style picker) with **Save as preset**; opened from a toolbar palette button; auto-presented on first boot.
- **`raymol_theme.py` (engine helper)** — given the palette: `set_color` swatches for the chain cycle + non-carbon element color names; `bg_color` for the background; set `auto_show_*` + remember the default rep so **new** objects load themed; expose `cbc()`/`cnc()`/`apply_default_style(obj)` the agent (and the load path) call. Does NOT touch existing objects on theme change.

## Application points
| Field | Applied via | When |
|---|---|---|
| appearance | `.preferredColorScheme` | immediately |
| accent / bubble / selectionName / tabTint | `PanelTheme` → SwiftUI | immediately |
| terminalFont / terminalText | `CommandPanel` console | immediately |
| viewportBackground | `bg_color` | immediately |
| chainCycle / elementColors | `set_color` defs + themed `cbc`/`cnc` | on NEW object load |
| defaultStyle | `auto_show_*` + `as <style>` | on NEW object load |
| outline | the silhouette/toon outline post-pass toggle | immediately (scene-wide) |
| flatSheets / fancyHelices | `set cartoon_flat_sheets` / `set cartoon_fancy_helices` | on NEW object load (cartoon settings) |

**New-object hook:** the load paths (the SwiftUI Open/Fetch flow and the agent's `run_python` loads) call `raymol_theme.apply_to(obj)` after loading. The agent is additionally told (system prompt) to use the themed helpers, satisfying decision 3.

## Phasing
- **C1 (app chrome):** Theme model + `ThemeManager` + `PanelTheme` refactor + appearance + chrome colors + terminal font/color + viewport `bg_color` + the popup (presets gallery, custom editor, save) + persistence + first-boot auto-present + toolbar button.
- **C2 (molecular + agent):** `raymol_theme.py` (chain/element `set_color`, `auto_show_*`, default rep, themed `cbc`/`cnc`) + new-object load hook + agent system-prompt instruction + `run_python` namespace helpers.

## Open implementation notes
- C1 is pure SwiftUI + one `bg_color`; low risk. C2 is the PyMOL-side work + a load hook.
- The `PanelTheme` refactor must be coordinated with A (ChatPanel bubble color) and B (ObjectPanel SettingsSheet) — do it after the A/B merge to avoid churn.
- Curated presets to ship (proposed): **Midnight** (current dark look), **Paper** (light/publication), **Terminal** (green-on-black, mono). Plus **System**.
- The detailed bite-sized task plan will be written after A/B merge, once the final state of the shared files is known.
