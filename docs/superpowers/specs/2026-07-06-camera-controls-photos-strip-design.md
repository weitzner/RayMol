# Camera controls — Photos-style icon strip (redesign) — design

**Date:** 2026-07-06
**Status:** draft (awaiting user review)
**Area:** macOS/iOS SwiftUI viewport chrome — replaces the camera overlay UI from
`2026-07-05-camera-overlay-design.md`. Reuses the same underlying scene-settings
controls and PyMOL plumbing.

## Problem

The current iPhone camera overlay (`cameraGlassCard` in `ContentView.swift`,
`CameraControlsView` in `ObjectPanel.swift`) is a full-width frosted card pinned
to the bottom that stacks a header plus **up to 9 label-and-control rows** (Lens,
Zoom, Ortho, Depth of field, and — when DOF is on — Auto lock, Focus, Aperture,
Quality) and a Reset button. In use it:

1. **Takes too much space** — 9 stacked full rows.
2. **Is hard to close** — dismissal is only a grab-handle tap or drag-down; no
   obvious close affordance.
3. **Covers too much of the viewer** — the card obscures roughly the bottom
   third-to-half of the molecule.

## Goal

Replace the card with an iPhone-Photos-style **bottom-docked icon strip**: a slim
row of icons where **one control opens at a time**. Minimal resting footprint,
the molecule stays visible, and closing is trivial. The same component ships on
**all platforms** (iPhone / iPad / macOS), replacing today's popover as well.

## Decisions (approved)

- **Interaction model (Photos "Adjust"):** a horizontal strip of icon buttons
  docked at the viewport bottom-center. Exactly one "surface" (a single slider,
  or the DOF sub-panel) is open at a time; opening another closes the previous.
- **Strip contents (essentials):** `Lens`, `Zoom`, `Ortho`, `Depth`, plus a
  trailing `Reset`. Curated by `SceneCatalog.cameraOverlayKeys` (unchanged source
  of truth, minus quality — see below).
- **Platforms:** all three. One shared bottom-docked strip; the macOS/iPad
  anchored `.popover` is removed.
- **DOF layout (Option B — dedicated sub-panel):** `Depth` opens a compact
  focused card above the strip; the base strip stays 4 icons that never scroll.
- **DOF sub-panel refinements (user):**
  - `Enabled` and `Auto lock` are both switches and **sit side by side on one
    row**; below them, `Focus` and `Aperture` sliders.
  - **`DOF quality` is removed from the strip** and lives only in the inspector's
    Scene panel ("settings"). It stays a `SceneParam` (group "Camera"), so no
    functional loss — just relocated.
  - **`metal_dof_quality` default changes `1 → 4`** so quality is a set-and-forget
    best-quality default; users rarely need to touch it.
- **No logic duplication:** every control reuses the existing `SceneParamRow`
  rendering and the existing PyMOL commands (`set_fov`, `setZoomMagnification`,
  `set ortho`, `set metal_dof*`, the autofocus `select dof_focus` action). This
  redesign is a re-presentation layer, not new control logic.

## Interaction design

### The dock
- The existing `cameraButton` chip (SF Symbol `camera`) stays at
  `.bottomLeading`. Tapping it shows/hides the whole dock (`showCameraPanel`).
- The dock is centered over the viewport bottom (`.overlay(alignment: .bottom)`),
  on a translucent `.ultraThinMaterial` pill sized to its content.
- A downward drag on the dock also dismisses it (keep the existing gesture).

### The strip (icons, left→right)
| Icon | Setting key | Type | SF Symbol (proposed) | Behavior |
|------|-------------|------|----------------------|----------|
| Lens | `field_of_view` | slider | `camera.aperture` | Opens a single slider (35mm-equiv mm via `fovToMM`/`mmToFOV`, applied with `set_fov`). Disabled/greyed while `ortho` is on. |
| Zoom | `zoom` | slider | `plus.magnifyingglass` | Opens a single slider (magnification via `setZoomMagnification`). |
| Ortho | `ortho` | toggle | `cube` | Toggles instantly (`set ortho, 0/1`); icon shows an "on" tint. Enabling it disables the Lens icon. |
| Depth | `metal_dof` | group | `camera.metering.center.weighted` (or `f.cursive`) | Opens the DOF sub-panel. Icon shows a small on-indicator dot when `metal_dof` is on. |
| Reset | — (action) | button | `dot.viewfinder` | Immediately runs `reset` (no open surface). |

Exact SF Symbols to be finalized during implementation; the mapping table lives
next to `cameraOverlayKeys`.

### Open-surface rules
- Tapping a **slider** icon (Lens/Zoom) opens its single slider above the strip;
  tapping the active icon again (or any other icon) collapses/replaces it.
- Tapping **Ortho** never opens a surface — it toggles immediately.
- Tapping **Depth** opens the DOF sub-panel (closing any open slider); tapping the
  active `Depth` again closes the sub-panel.
- Only one surface open at a time.

### DOF sub-panel (Option B, revised)
A compact card above the strip, titled "Depth of field":

1. Row 1 (two switches side by side): **Enabled** (`metal_dof`) · **Auto lock**
   (`metal_dof_autofocus`, keeps its on-action
   `select dof_focus, (sele)\nset metal_dof_autofocus, 1`).
2. **Focus** — `metal_dof_focus` slider (disabled while Auto lock is on).
3. **Aperture** — `metal_dof_aperture` slider.

When `metal_dof` is off, rows 2–3 (and Auto lock) render dimmed/disabled, so the
enable→adjust relationship is visible. `DOF range` and `DOF quality` are NOT
here (quality moved to settings; range was already inspector-only).

## Component architecture (SwiftUI)

- **New `CameraDock` view** (in `ObjectPanel.swift`, near `CameraControlsView`):
  renders the strip of icon buttons + the currently-open surface. Holds the
  open-surface selection (`@State`) and the DOF sub-panel expansion. Reads
  `engine.sceneState` and writes via `engine.runCommand` like the inspector.
- **Partitioning `cameraOverlayKeys`:** `CameraDock` splits the curated keys into
  the **base strip** (`field_of_view`, `zoom`, `ortho`, `metal_dof` → the four
  icons) and the **DOF group** (`metal_dof_autofocus`, `metal_dof_focus`,
  `metal_dof_aperture` → rendered inside the sub-panel, not as strip icons).
  `Reset` is a separate action button, not a key.
- **Open surface reuses `SceneParamRow`** for each control so all the special
  cases (Lens `set_fov`, Zoom magnification, ortho-inert Lens, autofocus-disabled
  Focus) are inherited unchanged.
- **`CameraControlsView` is repurposed** as the DOF sub-panel's body (the
  Enabled/Auto lock row + Focus/Aperture), or replaced by a small
  `DOFSubPanel` view — implementer's choice; keep it a thin composition of
  `SceneParamRow`s plus the side-by-side toggle row.
- **Icon mapping:** a small `[settingKey: SFSymbolName]` table beside
  `cameraOverlayKeys`.

### `ContentView.swift` changes
- Collapse `cameraGlassCard` and the platform branches of
  `cameraPanelPresentation` (`ContentView.swift:2439`) into a single shared
  bottom-docked `CameraDock` overlay used on **all** platforms.
- Remove the macOS/iPad `.popover(isPresented: $showCameraPanel...)` paths.
- Keep `cameraButton`, `showCameraPanel`, `bottomLeadingViewportChrome`, and the
  coexistence-with-scene-buttons layout.

## Settings / catalog changes

- `layer1/SettingInfo.h:940` — `REC_i(830, metal_dof_quality, global, 1)` →
  default `4`. (Read live in `SceneRender.cpp:2091`; requires a C++ rebuild.)
- `layerGraphics/metal/RendererMetal.h:513` — bump the `_dofQuality = 1` member
  initializer to `4` for consistency (cosmetic; overwritten by `setDofQuality`).
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift:195` — remove
  `"metal_dof_quality"` from `cameraOverlayKeys`. It remains in `params`
  (group "Camera"), so it still appears in the inspector Scene panel.
- No change needed to `appkit_inspector.py` (still polls `metal_dof_quality` for
  the inspector) or `raymol_scenes.py` (still snapshots it per scene).

## Files touched

- `swiftui/PyMOLViewer/Shared/ContentView.swift` — dock overlay; remove popover/
  card paths.
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — `CameraDock`, DOF sub-panel,
  icon map; trim `cameraOverlayKeys`.
- `layer1/SettingInfo.h` — DOF quality default 1→4.
- `layerGraphics/metal/RendererMetal.h` — `_dofQuality` init 1→4 (cosmetic).
- `swiftui/PyMOLViewerUITests/CameraOverlayUITests.swift` — rewrite to drive the
  icon strip + DOF sub-panel instead of the row list.

## Testing

- **Build:** two-stage — `swiftui/build_macos.sh` core THEN `xcodebuild` (avoids
  the stale `libpymol_core.a` gotcha). C++ default change requires a full core
  rebuild.
- **iOS simulator:** verify the touch layout, one-open-at-a-time behavior, DOF
  sub-panel, ortho-disables-lens, and dock dismissal.
- **macOS:** functionally test in an isolated VM (`mac-vm-test` skill) — the same
  strip now replaces the popover.
- **UI tests:** update `CameraOverlayUITests` to the new interaction and assert:
  strip icons present; Lens/Zoom open a single slider; Ortho toggles + greys
  Lens; Depth opens the sub-panel with Enabled/Auto lock side by side; quality is
  NOT in the strip; Reset works; chip hides the dock.
- **Regression:** confirm `metal_dof_quality` still appears in the inspector's
  Camera group and round-trips through `.pse` (via `raymol_scenes`).

## Non-goals

- No change to the DOF rendering pipeline, `set_fov` math, or zoom magnification
  math.
- No new camera settings; this is purely a UI re-presentation + two small
  defaults/relocation tweaks.
- The inspector Scene panel layout is unchanged except that quality is now only
  reachable there.

## Open questions

- Final SF Symbols for Lens/Ortho/Depth (proposed above; confirm during build).
- Whether the dock should auto-hide after a period of inactivity (default: no —
  it stays until the chip is tapped or dragged down).
