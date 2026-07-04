# Lens (focal-length) camera control — design

**Date:** 2026-07-04
**Status:** approved design (pending spec review)
**Area:** macOS/iOS SwiftUI+Metal app camera controls; PyMOL core view helpers

## Motivation

The **Field of view** slider currently just writes `field_of_view` (the vertical
FOV). Because the camera distance (`m_view.pos().z`) stays fixed, a wider FOV
makes the subject subtend a smaller angle, so it *shrinks* — the control reads
as a zoom, not as a change of lens. Apparent size scales as
`1 / (|pos.z| · tan(fov/2))`.

We want it to behave like **swapping physical lenses** (macro/telephoto ↔
fisheye): change the perspective (depth compression vs. exaggeration) while
keeping the subject the same size in frame. That is a **dolly zoom** — change
FOV *and* move the camera along z to hold framing constant.

## Decisions (from brainstorming)

1. **Replace**, don't augment: the single camera slider becomes the lens
   (dolly-compensated). Raw zoom-like FOV is no longer a UI slider; pinch/scroll
   still zooms (independently changes `pos.z`).
2. **Presentation: focal length in mm** (35 mm-equivalent), mapped to
   `field_of_view` under the hood. Relabel the control **Lens**.
3. **Wide end capped at ~15 mm (≈77° vertical FOV)** — strong wide-angle
   perspective without the camera entering the structure. (True 180° fisheye
   distortion is impossible with a rectilinear projection; "fisheye" here means
   very-wide rectilinear with strong perspective.)
4. **Auto-track the clip slab**: shift front/back clip by the dolly delta so the
   whole molecule stays visible as the lens changes.

## Focal length ↔ FOV mapping

PyMOL's `field_of_view` is the **vertical** FOV, so we map a 35 mm-equivalent
focal length through the full-frame sensor **height** (24 mm, half = 12 mm):

```
fov_v(f) = 2 · atan(12 / f_mm)          # degrees
f_mm(fov_v) = 12 / tan(fov_v / 2)       # inverse, for slider read-back
```

| Focal length | Vertical FOV | Feel |
|---|---|---|
| 15 mm | 77° | wide / "fisheye" (range max wide) |
| 24 mm | 53° | wide-angle |
| 35 mm | 38° | mild wide |
| 50 mm | 27° | normal |
| ~68 mm | 20° | PyMOL current default |
| 85 mm | 16° | portrait |
| 135 mm | 10° | macro / telephoto (range max long) |

**Slider range: 15 mm → 135 mm.** Vertical-FOV mapping is aspect-ratio
independent (vertical stays vertical across phone-portrait vs. mac-landscape).

## Behavior (the fix)

On a lens change from `fov_old` to `fov_new` (both vertical degrees):

```
dist = |pos.z|                                   # camera → rotation center
dZ   = dist · (tan(fov_new/2) / tan(fov_old/2) − 1)
```

- Set `field_of_view = fov_new`.
- Dolly the camera along z by `dZ` (shorter lens → camera moves in; longer →
  moves out), keeping the plane at the rotation center the same apparent size.
- Shift front/back clip by the same `dZ` so the slab tracks the subject.

This reuses the exact compensation already in the codebase
(`layer1/Scene.cpp:534`, the VR FOV-restore path). The anchor that stays framed
is the **rotation center** (`m_view.origin()` / center of interest) — the
natural "subject" for a molecule. Because `dist` is read from the *current*
view, the lens preserves whatever the user has already zoomed/framed.

## Architecture / components

### Core view helper — `modules/pymol/viewing.py`
Add `set_fov(fov, framed=1, animate=0, quiet=1, _self=cmd)`:
- Reads the current view (`pos.z`, clip, `field_of_view`).
- When `framed`: computes `dZ`, applies the dolly (camera z) + clip shift and
  sets `field_of_view` as one atomic view update (via the existing view
  machinery / `set_view`), so a single redraw shows the composed result.
- When `framed=0`: plain `set field_of_view` (raw, zoom-like) — preserves the
  old behavior for anyone who wants it and for scripts.
- Pure view transform → unit-testable with the PyMOL test harness.

Raw `set field_of_view, X` remains available (unchanged) for the ray tracer,
VR, and scripting; only the UI switches to the framed helper.

### SwiftUI control — `swiftui/PyMOLViewer/Panels/ObjectPanel.swift`
- Relabel the Camera-group control **Lens**, units mm, range 15–135, sensible
  step (e.g. 1 mm) — kept as a `.slider` `SceneParam`.
- The control's value **displays mm**, computed by inverting the mapping from
  the polled `field_of_view`. On drag it converts mm→fov and calls
  `set_fov(fov)` (framed) instead of `set field_of_view`.
- `field_of_view` is already in `SCENE_SETTINGS`, so the slider persists across
  screen changes (per the earlier persistence fix); the dolly'd `pos.z`/clip are
  ordinary view state saved with scenes/sessions.

### Data flow
`slider (mm) → mm→fov → cmd.set_fov(fov, framed=1) → viewing.set_fov reads
view, computes dZ, applies fov + camera-z + clip → redraw`. Read-back: scene
poll returns `field_of_view` → Swift inverts to mm → slider position.

## Edge cases

- **Orthographic mode** (`ortho` on): no perspective, so the lens has no visual
  effect. Disable/grey the Lens control when `ortho` is on (with help text), and
  leave `ortho`'s own toggle to switch back to perspective.
- **Wide extreme**: capped at 15 mm so the camera stays outside the structure;
  no special clamp logic needed beyond the slider min.
- **Independent zoom**: pinch/scroll still changes `pos.z` directly; the lens
  reads current `dist` each time, so the two compose cleanly.
- **Non-UI consumers** (`SceneRay.cpp`, VR): read `field_of_view` directly and
  are unaffected — the setting still holds the vertical FOV.

## Testing

- Unit-test the mm↔FOV mapping (round-trip; the anchor values in the table).
- Test `set_fov(fov, framed=1)`: a reference point at the rotation center keeps
  ~constant projected size across a lens sweep, while a point off the center
  plane changes size (perspective actually changed). Verify via `get_view` /
  projected coordinates.
- Verify `get_view`/`set_view` round-trips after a lens change.
- Verify `framed=0` reproduces the old raw behavior, and that raw
  `set field_of_view` (ray/VR paths) is byte-for-byte unchanged.

## Out of scope

- True fisheye (non-rectilinear) projection / barrel distortion.
- Animated lens transitions (could piggy-back on `set_view animate` later).
- A command-line `lens(mm)` wrapper (mm is a UI affordance; core helper takes
  degrees). Can be added trivially later if wanted.
