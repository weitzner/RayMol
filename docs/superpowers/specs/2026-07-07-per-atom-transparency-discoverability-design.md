# Per-atom transparency discoverability in the inspector

**Date:** 2026-07-07
**Issue:** [#122](https://github.com/javierbq/RayMol/issues/122) — "opaque cartoon objects render as semitransparent when two objects overlap"

## Background — what #122 actually is

The issue reported opaque cartoon rendering as semi-transparent when two objects
overlap, hypothesising z-fighting. Reproducing it against the reporter's
`stage2_compat.pse` showed the real cause: `dual_complex` has **per-atom
`cartoon_transparency`** baked in (chains B/C = 0.35, part of chain A = 0.6),
while APB27981 is opaque. The live viewport renders that transparency correctly;
it is neither z-fighting nor a rendering bug.

The reporter was misled because the object- and global-level `cartoon_transparency`
both read `0` — there was **no way to tell per-atom transparency was set**, and
the object-level transparency slider appeared not to work (per-atom values
override it). (A separate observation: the CPU ray tracer renders these solid,
i.e. it ignores per-atom `cartoon_transparency` — tracked separately.)

This feature makes per-atom transparency **discoverable and clearable** in the
inspector. It does not change how transparency renders.

## Design

### Detection — `modules/pymol/appkit_inspector.py`
- `TRANSP_SETTINGS = ['cartoon_transparency', 'sphere_transparency', 'transparency']`
  — the only transparency settings PyMOL supports **per-atom**. `ribbon_` and
  `stick_transparency` are object-level only (verified: `alter s.stick_transparency`
  raises "only atom-level settings can be set"), so they are excluded — they can
  never carry per-atom overrides.
- `REP_TRANSP` maps each rep to its setting (cartoon→cartoon_transparency,
  spheres→sphere_transparency, surface/mesh/dots→transparency).
- `transp_summary(obj)`: one `cmd.iterate` pass → `{setting: (min, max, over)}` of
  the **effective** per-atom transparency (atom-level value if set, else the
  object-level value). `over` = the range differs from the object-level value,
  i.e. the slider misrepresents what's rendered. Reading `s.<setting>` resolves to
  the object-level value for un-overridden atoms, so comparing the effective range
  to the object-level value is what detects a genuine override (no false alarm
  when per-atom == object-level).
- `object_has_atom_transp(obj)`: true when any **active** rep has an override
  (rep-gated so an override on a hidden rep doesn't flag). Drives the badge.
- `_build` attaches `atom_transp = {setting, min, max}` to a rep when its setting
  is overridden.

### Data path — `swiftui/.../PyMOLEngine.swift`
- The object-list poll (`OBJPANEL:` JSON) gains `has_transp: {obj: bool}` via
  `object_has_atom_transp`, so the collapsed-row badge works without expanding.
- `parseObjectDetailFeedback` parses `atom_transp` into `RepState.atomTransp`.

### UI — `swiftui/.../ObjectPanel.swift`
- `ObjectEntry.hasAtomTransp`, `RepState.atomTransp: AtomTransp?`.
- **Badge**: an amber `drop.halffull` icon on the object row (visible collapsed)
  when `hasAtomTransp`, with an explanatory tooltip.
- **Detail row**: in `RepPropertyGrid`, directly under the matching transparency
  slider (fallback: end of grid), an amber `per-atom: min–max` readout + a
  **Clear** button.
- **Clear** runs `unset <setting>, (<obj>)` + `rebuild <obj>` — the
  atom-selection form removes per-atom overrides while keeping the object-level
  slider value, restoring slider authority. (`alter, del s.<setting>` raises
  SystemError and bare `unset(setting, obj)` only touches the object level, so
  neither is used.)

### Scope guard (YAGNI)
No ray-tracer changes, no new settings, no change to how transparency renders —
purely making existing behaviour discoverable and clearable.

## Verification
- Headless unit tests (`testing/tests/test_inspector_transparency.py`, 7 cases):
  clean object, partial/uniform overrides, no-false-alarm when per-atom==slider,
  Clear restores slider authority, rep-gating, non-atom-level exclusion.
- Full data contract validated headlessly against the real `stage2_compat.pse`.
- macOS build succeeds; functionally verified in an isolated VM against the PSE:
  badge on `dual_complex` only, `per-atom: 0–0.6` detail row under the cartoon
  Transparency slider, and Clear (unset 5825 atoms) → badge + row disappear and
  the cartoon renders opaque.
