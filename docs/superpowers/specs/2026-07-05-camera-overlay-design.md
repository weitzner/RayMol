# Camera-settings overlay (bottom-left viewport shortcut) — design

**Date:** 2026-07-05
**Status:** approved
**Area:** macOS/iOS SwiftUI viewport chrome; reuses the existing scene-settings controls

## Goal

A camera icon at the bottom-left of the 3D viewport that opens a compact overlay
of camera controls, so common viewpoint/lens/depth-of-field adjustments are one
tap away without opening the full inspector.

## Decisions (approved)

- **Control set (as sketched):** Lens (mm), Orthographic, Depth of field →
  (Auto lock focus, Focus, Aperture, High quality), and Reset view.
- **Presentation:** anchored **popover** on macOS/iPad (regular width); **bottom
  sheet** on iPhone (compact width).
- **Label rename:** the `metal_dof_autofocus` control is renamed from
  "Autofocus (lock to selection)" to **"Auto lock focus"** — in the shared
  `SceneParam`, so the inspector and the overlay stay consistent.
- **Single source of truth:** the overlay reuses the inspector's existing scene
  controls (see Reuse). The controls also remain in the inspector; the overlay is
  a shortcut, not a move.

## Controls (exact rows)

Rendered in this order, all reading `engine.sceneState` and writing via
`engine.runCommand` exactly as the inspector does today:

1. **Lens** — `field_of_view`, slider, shown as 35mm-equivalent mm (12–135) via
   `fovToMM`/`mmToFOV`, applied with `set_fov` (dolly-zoom). Disabled/greyed when
   `ortho` is on (existing behavior).
2. **Orthographic** — `ortho`, toggle. **New `SceneParam`** added to the "Camera"
   group (`set ortho, 0/1`). `ortho` is already polled (it's in
   `appkit_inspector.py` `SCENE_SETTINGS`), so it persists across screens.
3. **Depth of field** — `metal_dof`, toggle. When on, reveals (via the existing
   `dependsOn: metal_dof` + `visible()` gate):
   - **Auto lock focus** — `metal_dof_autofocus`, toggle (renamed). Keeps its
     special on-action: `select dof_focus, (sele)\nset metal_dof_autofocus, 1`.
   - **Focus** — `metal_dof_focus`, slider (disabled while Auto lock focus is on).
   - **Aperture** — `metal_dof_aperture`, slider.
   - **High quality** — `metal_dof_hq`, toggle.
4. **Reset view** — button → `engine.runCommand("reset")` (the `reset_view`
   action's command, `ObjectPanel.swift:584`).

Note: `metal_dof_range` and `depth_cue/fog` are intentionally NOT in the overlay
(the user chose the "as sketched" set); they stay in the full inspector.

## Placement and activation

- A `CameraButton` (SF Symbol `camera`, in a translucent rounded-square chip
  matching existing chrome) lives in the viewport's
  `.overlay(alignment: .bottomLeading)` on both platforms (macOS `ContentView`
  ~386, iOS ~1426).
- It toggles a `@State private var showCameraPanel` in `ContentView`. The chip
  shows a pressed/tinted state while the panel is open.
- **Coexistence with scene buttons:** the optional scene-buttons overlay also
  anchors bottom-leading. Lay the camera chip as the leftmost item with the
  scene-buttons row beside/above it (a leading `HStack`/`VStack`) so they never
  overlap. Same transport clearance the scene buttons use (`.padding(.bottom,
  hasTimeline ? 96/56 : 12)`).
- **Visibility:** shown only when a structure is loaded (`!engine.objects.isEmpty`),
  matching the other viewport overlays and the empty-state CTA.

## Presentation per platform

Branch on `horizontalSizeClass` (already used as `hSize`, `ContentView:635`):

- **Regular (macOS / iPad):** `.popover(isPresented: $showCameraPanel, arrowEdge:
  .bottom)` anchored to the chip, content in a fixed ~300pt-wide container, with
  `.presentationCompactAdaptation(.popover)` (as the existing pane popover,
  `ContentView:1333`). Tap-outside / re-tap dismisses.
- **Compact (iPhone):** `.sheet(isPresented: $showCameraPanel)` with
  `.presentationDetents([.medium])` and `.presentationDragIndicator(.visible)`;
  same content. Swipe-down / re-tap dismisses; dims the view (native).

The overlay content is one shared `CameraControlsView` used by both branches.

## Reuse / targeted refactor

The inspector currently renders a scene row via private methods on its panel view:
`paramRow` → `sceneControl` (with the `field_of_view` lens and
`metal_dof_autofocus` special-cases, and the `metal_dof_focus` auto-disable),
`sceneRow` (label 110pt + control + help), `visible()` (dependsOn gate), and the
`fovToMM`/`mmToFOV`/`fmtScene` helpers (`ObjectPanel.swift` ~2026–2142).

Extract these into a **reusable `SceneParamRow` view** (`SceneParamRow(param:
SceneParam, engine: PyMOLEngine)`), moving the special-cases with it. Then:
- the inspector's scene section renders `SceneParamRow` per param (no behavior
  change), and
- `CameraControlsView` renders `SceneParamRow` for the camera params it selects
  (`SceneCatalog.params.filter { $0.group == "Camera" }`, honoring `visible()`),
  plus the Reset view button.

This keeps one implementation of the lens/DOF/autofocus logic. No new command
paths, no core/C++ change, no `.pse`/settings change.

## Data flow

Identical to the inspector: controls read `engine.sceneState.values[...]` (the
~500ms scene poll) and write with `engine.runCommand("set …")` / `set_fov` /
`reset`. The poll re-syncs the controls after each set. All camera settings are
already in `SCENE_SETTINGS`, so values persist across screen changes.

## Edge cases

- **Ray-trace / DOF unsupported GPU:** not applicable — the overlay has no
  `metal_raytrace` row. DOF works on all supported targets.
- **Ortho on:** Lens row greyed (existing).
- **No selection + Auto lock focus:** falls back to center-of-interest (existing
  autofocus behavior; unchanged).
- **Timeline present:** camera chip + panel clear the transport bar.
- **Empty scene:** camera chip hidden.

## Testing

- Build macOS + iOS (Swift-only; no core rebuild).
- Functional (sim/VM): chip appears when a structure is loaded; tap opens the
  popover (mac) / sheet (iPhone); Lens drags change perspective live; Orthographic
  toggles and greys Lens; Depth of field reveals its sub-rows; Auto lock focus
  snapshots the selection; Reset view recenters; re-tap / tap-outside / swipe-down
  dismisses; values survive a screen change (poll) and a session round-trip.
- Confirm the inspector's Camera section is unchanged after the `SceneParamRow`
  extraction (same rows, same behavior, renamed autofocus label).

## Out of scope

- Adding new camera settings (clip/slab controls, per-row DOF range in the
  overlay, depth-cue in the overlay).
- Any C++/core, `.pse`, or renderer change.
- A draggable/repositionable panel.
