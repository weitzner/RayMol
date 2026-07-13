# Move mode — rigid-body object manipulation (UI/UX design spec)

Status: approved design, in implementation on branch `feat/move-mode`.
Date: 2026-06-29.

## 1. Problem & goal

Vanilla PyMOL has an editing mouse mode (`three_button_editing`) that lets you move
individual objects/molecules around independently of the camera. In RayMol
(SwiftUI + Metal fork) that path is effectively dead: the editing drag relies on
`SceneClick`→`SceneDoXYPick` (GL color picking), which does nothing on the Metal
backend (`internal_gui=0`). RayMol already replaced picking with a CPU projection
(`modules/pymol/metal_pick.py`).

Goal: a first-class **Move mode** — a peer to the existing Measure mode — for
**rigid-body repositioning of whole objects**, with an on-screen manipulation
gizmo, on both macOS and iPad/iOS.

## 2. Scope (v1)

In scope:
- Rigid-body **translate** and **rotate** of a whole object via its **TTT matrix**
  (`cmd.translate`/`cmd.rotate` with `object=`). Non-destructive (atom coordinates
  never change), reversible, saved in `.pse`.
- On-screen gizmo with a **Move / Rotate** tool toggle.
- macOS + iPad + iPhone.

Out of scope (noted as future):
- Atom / fragment / torsion editing (destructive coordinate edits, `protect`,
  sculpting).
- "Bake to coordinates" (apply TTT into real xyz).
- Group / multi-object simultaneous move.
- Global/Local axis-frame toggle (v1 is world axes only).

## 3. Decisions (from brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| Scope | What can move | Rigid-body whole objects (TTT), non-destructive |
| Target | Which object a drag moves | Grab-what-you-touch + active lock with overlay indicator + dropdown override |
| macOS mapping | Reassigning the mouse | Mode-first: gizmo handles move the object; empty-space drag still orbits camera |
| Affordance | On-screen control | On-screen gizmo (both platforms) |
| Tool model | Translate vs rotate | Segmented **Move / Rotate** toggle in the overlay (mirrors Measure's Distance/Angle/Dihedral) |
| Axis frame | What arrows mean | World axes for the X/Y/Z arrows + a free screen-plane center handle |
| Touch model | Engaging a handle | Both: direct drag a knob, **or** tap a knob to arm an axis then drag anywhere |

## 4. Interaction model (shared)

- **Active object.** Tapping/clicking an object makes it the active object; a gizmo
  appears at its displayed center and its name shows in the overlay (with a dropdown
  to override). Tapping empty space clears the active object and hides the gizmo.
- **Gizmo, Move tool:** three world-axis arrows (X red, Y green, Z blue), an XY
  **plane handle**, and a white **center handle** (free screen-plane drag).
- **Gizmo, Rotate tool:** three world-axis rotation rings + an outer screen-rotation
  ring.
- **Camera navigation is always preserved.** Dragging off the gizmo orbits/pans the
  camera; pinch zooms; two-finger drag orbits. The gizmo handles are the only thing
  that moves the object.
- **Live readout** in the overlay during a drag: e.g. `ΔX +3.2 Å`, `↻Y +24°`.
- Move mode and Measure mode are **mutually exclusive** (entering one exits the other).

## 5. macOS UI/UX

- **Entry points:**
  - Toolbar toggle (`arrows.move` → `arrows.move` filled when active) next to the
    measure ruler in the window toolbar.
  - Menu command under a new **Mouse** menu group: "Move Objects" with shortcut
    **⌃M** (toggles the mode).
- **Mouse semantics in Move mode:**
  - Left-drag starting on a gizmo handle → manipulate that handle.
  - Left-drag starting off the gizmo → orbit camera (unchanged).
  - Left-click (no drag) on an object → set it active (show gizmo).
  - Left-click on empty space → clear active object.
  - `⇧` while dragging a handle → snap (15° rotation / 1 Å translation). `⌥` → fine.
  - Right-drag / middle-drag / scroll → unchanged camera zoom/pan/slab.
- **Overlay** (top of viewport, mirrors `measureOverlay`): segmented Move/Rotate ·
  active-object dropdown · live readout · "Reset position" · exit ✕.
- Subtle outline highlight on the active object in addition to the gizmo.

## 6. iPad / iOS UI/UX

- **Entry point:** navigation-bar toggle (mirrors `iosMeasureToolbar`'s ruler). The
  overlay docks beneath the nav bar. On **iPhone (compact)** the overlay collapses
  to icon-only segments + a tappable readout chip.
- **Touch semantics in Move mode:**
  - Tap a gizmo knob → arm that axis (highlighted); tap again to disarm.
  - Tap an object (not a knob) → set it active.
  - Tap empty space → clear active object + disarm.
  - One-finger drag starting on a knob → manipulate it directly.
  - One-finger drag with an axis armed (started off a knob) → manipulate the armed axis.
  - One-finger drag otherwise → orbit camera (unchanged).
  - Pinch = zoom, two-finger drag = orbit (unchanged).
- Handles use enlarged grab knobs (≥44 pt hit area).

## 7. Architecture & data flow

### 7.1 State (Swift, `PyMOLEngine`)
New `@Published` state alongside `measureMode`/`trackpadMode`:
- `interactionMode: InteractionMode` — `.viewing` | `.move`.
- `moveTool: MoveTool` — `.translate` | `.rotate`.
- `activeMoveObject: String?`.
- `armedAxis: GizmoHandle?` (iOS tap-to-arm).
- `gizmo: GizmoGeometry?` — projected handle geometry for drawing + 2D hit-testing.
- `moveReadout: String`.

### 7.2 Python (`modules/pymol/metal_move.py`)
Owns all 3D→2D projection (reusing the verified `cmd.get_view` layout documented in
`metal_pick.py`) and all manipulation (`cmd.translate`/`cmd.rotate`). It writes the
gizmo geometry as JSON to `<tmpdir>/pymol_gizmo.json`, which Swift reads
synchronously after each call (the `longPressPick` pattern) for responsive,
poll-free updates.

Functions:
- `set_active(obj, tool, aspect)` / `clear_active()` — set module state, recompute.
- `set_tool(tool, aspect)` — switch translate/rotate, recompute.
- `refresh(aspect)` — recompute + rewrite gizmo JSON (called when the camera changes).
- `pick_object(ndc_x, ndc_y, aspect)` — return object under cursor (reuses
  `metal_pick._pick_atom`).
- `begin_drag(handle, ndc_x, ndc_y, aspect)` / `update_drag(ndc_x, ndc_y, aspect)` /
  `end_drag()` — gesture lifecycle; `update_drag` applies the incremental delta,
  accumulates the readout, rewrites the JSON. `end_drag` closes the undo step.
- `reset_active()` — `matrix_reset` on the active object.

Geometry contract (`pymol_gizmo.json`):
```
{ "active": true, "obj": "1abc", "tool": "translate",
  "center": [ndc_x, ndc_y],
  "axes":   { "x":[ndc_x,ndc_y], "y":[...], "z":[...] },   // arrow tips (translate)
  "plane":  [ndc_x, ndc_y],                                  // XY plane handle (translate)
  "rings":  { "x":[[ndc_x,ndc_y],...], "y":[...], "z":[...], "screen":[...] }, // rotate
  "readout": "ΔX +3.2 Å" }
```
All NDC are in PyMOL convention (bottom-left origin, +y up), matching what the
`MetalViewport` gesture handlers already compute from event locations on both
platforms.

Manipulation math:
- Axis arrow: project the world axis to a screen direction at the object's depth,
  least-squares the pointer delta onto it to get a world distance, then
  `cmd.translate([axis*dist], object=obj, camera=0)` (world frame → TTT translate).
- Center handle: `cmd.translate([dx_world, dy_world, 0], object=obj, camera=1)` where
  the NDC delta is scaled by the half-extent at the object's depth.
- Rings: signed screen-angle delta about the projected center →
  `cmd.rotate(axis, deg, object=obj, origin=center, camera=0)` (screen ring → `'z'`,
  `camera=1`).

### 7.3 Gizmo rendering (Swift, `GizmoOverlay.swift`)
A non-interactive SwiftUI `Canvas` over the viewport. It reads `engine.gizmo`,
converts PyMOL NDC → top-left view points (`px=(ndc_x+1)/2*W`,
`py=(1-ndc_y)/2*H`), and strokes arrows / plane handle / center / rings with the
axis colors. `allowsHitTesting(false)` — all input is handled in `MetalViewport`.

### 7.4 Gesture routing (Swift, `MetalViewport`)
The single input pipeline. Handlers branch on `engine.interactionMode == .move`:
hit-test `engine.gizmo` in 2D (NDC) at the gesture's start point; if a handle is hit
(or an axis is armed on iOS), drive `engine.gizmoBeginDrag/updateDrag/endDrag`;
otherwise fall back to the existing camera path. During camera orbit in Move mode,
call `engine.refreshGizmo()` per tick so the gizmo tracks (consistent with the
existing per-tick `runPython` used by zoom/Z-roll).

### 7.5 Independence from PyMOL `mouse_mode`
Move mode intercepts gestures in Swift before the core button/drag path, so it works
on Metal where `three_button_editing`'s GL-pick path is dead. The `MousePanel`
mouse-mode ring is left as the advanced/desktop-parity surface.

## 8. Edge cases
- No object loaded / active object deleted → hide gizmo, disable tools (re-validate
  active object name in `refresh`).
- Existing TTT (e.g. from `align`) composes correctly (`cmd.translate`/`rotate`
  combine onto the current TTT).
- Multi-state / trajectory objects: TTT is object-wide — unaffected.
- `reset` resets the camera, not object TTTs; "Reset position" is the explicit TTT
  reset.
- Undo: a completed drag is one undo step (`cmd.push_undo` in `begin_drag`).

## 9. Testing
- Headless (existing `PYMOL_AUTO*`/MCP harness): enter Move mode, set active object,
  apply a known delta, assert `cmd.get_object_matrix` / TTT changed by the expected
  amount; `capture_viewport` to confirm the gizmo renders.
- Swift unit tests for the NDC↔point conversion and 2D handle hit-testing.
- XCUITest: toggle + overlay presence on iOS.

## 10. Files
- `modules/pymol/metal_move.py` — new.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — state + methods + gizmo JSON read.
- `swiftui/PyMOLViewer/Shared/GizmoOverlay.swift` — new (Canvas overlay + types).
- `swiftui/PyMOLViewer/Shared/MetalViewport.swift` — gesture routing.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` — overlay bar + toolbar toggles.
- `swiftui/PyMOLViewer/Shared/PyMOLApp.swift` — macOS menu command + shortcut.
