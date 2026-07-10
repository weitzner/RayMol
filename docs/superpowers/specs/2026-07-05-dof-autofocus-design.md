# DOF autofocus (lock focus to a selection) — design

**Date:** 2026-07-05
**Status:** approved
**Area:** macOS/iOS SwiftUI+Metal DOF; PyMOL core scene render

## Goal
An autofocus mode that keeps a chosen element in focus as the camera zooms/rotates/pans — so a selected residue/atom stays sharp while everything else blurs according to depth of field.

## Decisions (from brainstorming)
- **Lock on enable:** snapshot whatever is selected when autofocus is turned on; stays locked to that element even if the user later selects something else. Re-arm by toggling off→on.
- **Fallback:** if nothing is selected at enable time (empty target), behave like today's auto-focus — focus the center of interest (rotation origin).

## Mechanism
The DOF auto-focus already recomputes the focal distance every frame from a 3-D point: it transforms the rotation origin into eye space and uses its depth (`SceneRender.cpp`, the `dofFocus <= 0` block). Autofocus reuses this, swapping the point for the locked selection's centroid — so tracking as the camera moves is automatic.

### Setting + locked target
- New global bool `metal_dof_autofocus` (SettingInfo.h, index 829, default false).
- Locked target = a snapshot selection named **`dof_focus`**. Enabling autofocus copies the current selection into it: `select dof_focus, (sele)` then `set metal_dof_autofocus, 1`. Because it's a copy, later changing `sele` doesn't move the focus.

### Per-frame focus (SceneRender.cpp, the auto-focus block)
```
dofFocus = metal_dof_focus (setting)
if metal_dof_autofocus:
    dofFocus = 0                      # ignore the manual slider
    if ExecutiveGetExtent(G,"dof_focus",mn,mx, transformed=true, state=-1, weighted=false):
        c = (mn+mx)/2                 # selection centroid, world space
        ez = mv[2]*c.x + mv[6]*c.y + mv[10]*c.z + mv[14]
        if -ez > 0: dofFocus = -ez    # eye-space depth
if dofFocus <= 0:                     # manual-auto (0) OR autofocus w/ empty target
    ez = origin transformed by mv; dofFocus = -ez
```
Runs every frame → the element stays sharp through camera zoom/rotate/pan (and object/trajectory motion, since the centroid is re-queried). Overrides the manual DOF-focus slider while on.

### UI (ObjectPanel.swift, Camera → Depth of field)
- New toggle **"Autofocus (lock to selection)"**, `dependsOn: metal_dof`.
- Special-cased on-action (like the Lens slider): ON → `select dof_focus, (sele)` + `set metal_dof_autofocus, 1`; OFF → `set metal_dof_autofocus, 0`.
- The manual **DOF focus** slider is disabled/greyed while autofocus is on (autofocus drives it).
- `metal_dof_autofocus` added to the scene-state poll (appkit_inspector.py `SCENE_SETTINGS`) so the toggle + the slider-disable state persist across screens.

## Edge cases
- `dof_focus` empty / undefined (nothing selected, or selection later deleted) → origin fallback (no crash, DOF still works).
- DOF off → toggle is hidden (gated on `metal_dof`).
- Ray tracer / non-Metal: unaffected (this only changes the eye-space focus fed to the Metal DOF pass; `metal_dof_focus` semantics for other consumers unchanged).

## Testing
Sim: select a residue, enable autofocus, zoom in/out and rotate → the selected residue stays crisp while nearer/farther elements blur and re-sharpen correctly; a non-selected residue does not stay in focus. Toggle off → manual/auto focus returns. Empty selection + autofocus → center-of-interest focus (no crash).

## Out of scope
- Continuous "follow the live selection" mode (we chose lock-on-enable).
- A tap-to-focus gesture (could layer on later: tap sets `dof_focus`).
