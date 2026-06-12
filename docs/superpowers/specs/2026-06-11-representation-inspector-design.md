# Representation Inspector Panel — Design Spec

**Date:** 2026-06-11
**App:** native macOS SwiftUI PyMOL (`swiftui/PyMOLViewer/`, branch `swiftui-cross-platform`)
**Goal:** Per-structure, expand-in-place inspector giving precise control over every active representation's renderable properties (visibility, color, transparency, rep-specific), plus a global "Scene" parameters section.

Chosen direction: **C (card accordion) + B's precision** — expand a structure → representation chips → property grid; every continuous value is a slider paired with an editable numeric field; custom RGB color wells; all representations covered.

---

## 1. Interaction model

- The existing object row (toggle · name · A/S/H/L/C) gains a **disclosure chevron**. Clicking expands the card **in place**.
- Expanded card shows:
  - **Object color row** (Layer-1 baseline): presets `by element / by chain / by ss / spectrum` + named-color menu + custom color well. Runs `cmd.color` / `util.cb*` / `spectrum` (per-atom color).
  - **Representation chips**: one per *active* rep, highlighted; each chip has an eye-dot to toggle visibility; a **`+`** chip opens a menu of not-yet-shown reps (`show <rep>, obj`). Selecting a chip shows its property grid.
  - **Property grid** for the selected rep: label-left / control-right rows, including per-rep **Color** (Layer-2 override).
- A collapsible **Scene** card (global params) is pinned at the top of the panel.
- Multiple cards may be expanded simultaneously. Selections keep their existing action row (no rep grid).

## 2. Two-layer color model

- **Layer 1 — object/atom color** (per-atom). Set by the object color row (`cmd.color name, obj` / `util.cbc(obj)` / `spectrum`). Every rep whose override is "Inherit" follows it.
- **Layer 2 — per-rep override**: `<rep>_color` settings, default `-1` ("Inherit"). The per-rep Color control writes `set <rep>_color, <color>, obj`; choosing **Inherit** writes `set <rep>_color, -1, obj` (labels default `-6`). Override settings: `cartoon_color, surface_color, stick_color, sphere_color, ribbon_color, mesh_color, dot_color, line_color, label_color`.
- Color wells support **custom RGB**: allocate a named color via `set_color tmp_<obj>_<rep>, [r,g,b]` then apply it (object color or rep override). Reuse a stable temp-color name per (obj,rep) slot so repeated edits don't leak color indices.

## 3. Per-representation property set

Every rep: **Visibility** (show/hide), **Color** (override, §2), **Transparency**. Plus rep-specific:

| Rep | Transparency setting | Rep-specific controls |
|---|---|---|
| cartoon | `cartoon_transparency` | type seg (automatic/tube/loop via `cartoon_*` flags or `cartoon_tube_radius`), `cartoon_fancy_helices` (bool) |
| surface | `transparency` | `surface_quality` seg (0/1/2), `surface_mode` seg, `solvent_radius` |
| sticks | `stick_transparency` | `stick_radius`, `stick_h_scale` |
| spheres | `sphere_transparency` | `sphere_scale` |
| nb_spheres | `nb_spheres_size`* | `nb_spheres_size` |
| mesh | `transparency`* | `mesh_width`, `mesh_quality` |
| ribbon | `ribbon_transparency` | `ribbon_width`, `ribbon_sampling` |
| lines | — | `line_width` |
| dots | `transparency`* | `dot_density` seg, `dot_radius` |
| nonbonded | — | `nonbonded_size` |
| labels | `label_color` only | `label_size` |

(*surface/mesh/dots transparency all read the shared `transparency` setting; nb_spheres has no dedicated transparency.)

## 4. Controls (precision)

- **LabeledSlider**: slider (live drag) + editable numeric field (commit on enter/blur). Debounced writes (~30 ms) so drags don't flood the command queue.
- **SegmentedSetting**: enum/int choices (quality, cartoon type, dot density 1/2/3).
- **ToggleSetting**: bool settings (macOS switch).
- **ColorControl**: menu of presets (`Inherit`, by element/chain/ss, spectrum, named colors) + a native `NSColorWell` (custom RGB). Shows current swatch.
- Each property row knows its setting name, type, range/options, default, and scope; the grid is **data-driven** from a metadata table (§6) so "all reps" is a table-fill.

## 5. Global "Scene" panel

Grouped (from B):
- **Appearance**: Background color (`bg_rgb` via color well).
- **Lighting & Quality**: Shadows (`metal_shadows`), Ambient occlusion (`metal_ssao`), Outline (`metal_outline`), MSAA 4× (`metal_msaa`), Depth-cue/fog (`depth_cue` + `fog`).
- **Camera**: Field of view (`field_of_view`), default Surface quality (`surface_quality`).

Bound to global `get`/`set`; values read by the same poll.

## 6. Data layer

- New Swift model types:
  - `RepProperty { settingName, label, kind(.slider/.segmented/.toggle/.color), min/max/step or options, scope(object), repColorSetting? }`
  - `RepSpec { repName, colorSetting, defaultColorIndex, [RepProperty] }` — static table in `RepProperties.swift` covering all reps.
  - `RepState { repName, visible, values:[String:Double], colorLabel:String }`
  - `ObjectDetail { reps:[RepState], … }`; `@Published var objectDetails:[String:ObjectDetail]` on `PyMOLEngine`.
  - `SceneState { values:[String:Double], bgColor, … }`; `@Published var sceneState`.
- New throttled poll `pollDetails()` (≈ every 500 ms, alongside `pollObjects`): for each **expanded** object only (perf), emit JSON of active reps (`count_atoms("(obj & rep X)")>0`) + `get` of each exposed setting scoped to the object, + global scene settings. Parse into the models on the main thread. (Polling only expanded objects keeps it cheap; collapsed cards don't query.)
- Writes via `engine.runCommand`: `set <setting>, <val>, <obj>`, `show|hide <rep>, <obj>`, `color`/`util.*`/`spectrum`, `set_color`. Slider drags debounced in the control.

## 7. Files

- `PyMOLViewer/Shared/PyMOLEngine.swift`: models + `pollDetails()` + parse + which objects are "expanded" (a `Set<String>` the panel updates).
- `PyMOLViewer/Panels/ObjectPanel.swift`: disclosure, object color row, chips, property grid, Scene card. Reuse `PanelTheme`/`PanelButtonStyle`.
- `PyMOLViewer/Panels/InspectorControls.swift` (new): `LabeledSlider`, `SegmentedSetting`, `ToggleSetting`, `ColorControl`.
- `PyMOLViewer/Panels/RepProperties.swift` (new): `RepProperty`, `RepSpec`, the metadata table, scene-params table.

## 8. Edge cases / non-goals

- Selections: no rep grid (action row unchanged).
- Per-rep **reset**: small reset control writes the setting default (object scope `unset` or set to default).
- v1 applies properties at **object scope** (not per-selection sub-scoping).
- Custom-color temp indices reused per (obj,rep) slot to avoid leaks.
- No undo integration beyond PyMOL's own; no animation of slider→render (live).

## 9. Verification

- Build app (Swift-only; no core change) → launch with a scene (cartoon+surface+sticks).
- Screenshot-verify: expand 1ubq, set `surface_color` grey70 while cartoon stays spectrum (the two-layer test); drag surface transparency and confirm render updates; toggle a Scene param (shadows) and confirm; custom RGB well changes a rep color.
- Regression: object enable/disable, A/S/H/L/C menus, selections still work.
