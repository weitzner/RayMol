# Adaptive cartoon LOD + display-aware upscale — design

Date: 2026-07-02
Status: approved (design), pending spec review
Related: issue #87, PR #88/#92 (metal_shadow_bias). This is a *quality/performance*
follow-up, not an acne fix — the shadow-bias work already removes the "triangles".

## Motivation

Raising `cartoon_sampling` gives crisp β-strand/ribbon geometry (and further
softens any residual faceting) but tessellates the whole object at all times, so
it costs performance. `metal_upscale` (render at 0.667× + MetalFX) claws back
perf but the upscale blur is objectionable on low-DPI (non-Retina) external
displays, while looking fine on the built-in Retina display.

Goal: a single adaptive system that (A) gives high cartoon detail **only when it
is visible** — i.e. when zoomed in — and drops it when zoomed out, and (B) only
enables the reduced-res upscale on displays where it looks acceptable.

Measured (whole-object `rebuild`+`refresh`, RayMol Metal, host):

| structure | atoms | samp 7 | samp 14 | samp 20 | samp 30 |
|---|---|---|---|---|---|
| 1ubq | 660 | 0 ms | 1 | 1 | 1 |
| 256b | 1.9k | 1 | 2 | 4 | 4 |
| 1hho | 2.4k | 2 | 3 | 4 | 7 |
| 1aon (GroEL) | 59k | 48 | 89 | 104 | 174 |

⇒ a debounced whole-object rebuild is imperceptible (1–7 ms) for realistic
structures and bounded (~175 ms one-time) at GroEL scale. **Per-region / GPU
tessellation is therefore out of scope** — not needed.

## Non-goals

- No view-dependent / per-region tessellation; no GPU-tessellated cartoon rewrite.
- No change to the `metal_shadow_bias` acne fix (orthogonal, stays as-is).
- Adaptive rebuild happens only when the camera **settles**, never during a drag.

## Component A — Zoom-adaptive cartoon tessellation

### Settings (layer1/SettingInfo.h)
- `cartoon_sampling_dynamic` (bool, **default on**) — enable adaptive LOD.
- `cartoon_sampling_max` (int, default **-1 = auto**) — detail ceiling when
  zoomed in. Auto resolves by atom count via the existing `GetCartoonQuality`
  pattern so large structures cap lower (illustrative: <10k→18, <50k→12,
  <200k→8, else 5), bounding the worst-case rebuild.

When `cartoon_sampling_dynamic` is **off**, behavior is byte-identical to today
(static `cartoon_sampling`). When on, the app OWNS `cartoon_sampling`, driving it
between a floor (~3) and `cartoon_sampling_max`.

### Zoom metric
Compute **Å-per-pixel** at the structure center from the live camera:
`angstrom_per_pixel = (2 * camera_distance * tan(fov/2)) / viewport_height_px`,
where `camera_distance` and `fov` come from `get_view` + `field_of_view`, and
`viewport_height_px` from the drawable size. Small Å/px = zoomed in (residues
span many pixels → facets visible → need detail); large Å/px = zoomed out.

### LOD buckets + hysteresis
Discrete buckets map Å/px → target sampling (illustrative, calibrate empirically):

| Å/pixel | sampling |
|---|---|
| > 0.5  | 3 (floor) |
| 0.25–0.5 | 5 |
| 0.10–0.25 | 8 |
| 0.05–0.10 | 12 |
| < 0.05 | `cartoon_sampling_max` |

Hysteresis: switching to a higher bucket requires crossing its threshold by a
margin (~20%) tighter than the switch-down threshold, so a zoom that hovers on a
boundary does not thrash rebuilds.

### Trigger / debounce
On camera change, start/reset a **~200 ms debounce**. When it fires (zoom
settled), compute the target bucket; if it differs from the current sampling,
run `set cartoon_sampling, N` then `rebuild` on the main thread (the existing
path). Never rebuild mid-gesture.

### Ownership
LOD math + debounce live in Swift (`MetalViewport` / `PyMOLEngine`), where camera
and gesture events already are. They call the existing engine command path. No
core rendering changes.

### Edge cases
- Object with no cartoon shown → no-op (rebuild is cheap/no cartoon rep).
- User manually `set cartoon_sampling, N` while dynamic is on → treated as a
  temporary override until the next bucket change; document that dynamic owns the
  value (use `cartoon_sampling_max` to pin the ceiling, or turn dynamic off).
- Multiple objects → LOD is global (one `cartoon_sampling`); acceptable.
- `.pse` load / reinitialize → recompute on next settle.

## Component B — Display-aware reduced-res upscale

### Setting change (layer1/SettingInfo.h)
`metal_upscale` bool → **int, values 0=off / 1=on / 2=auto, default 2**. `0/1`
retain today's meaning (backward compatible; the REC_b default false becomes
REC_i default 2).

### Auto rule
When `metal_upscale == 2`, the **effective** upscale = *is the window's current
display Retina?* (`NSScreen.backingScaleFactor >= 2`). Retina hides the 0.667×
blur; low-DPI externals do not. (Chosen over ProMotion-only because a 5K 60 Hz
Retina display also benefits and looks fine.)

### Detection + re-evaluation
Swift reads `view.window?.screen?.backingScaleFactor`. Recompute on
`NSWindow.didChangeScreenNotification` (window dragged to another display) and on
`didChangeBackingProperties`. The computed effective flag feeds the renderer's
existing `_upscaleEnabled` (via `setPostParams`' `upscaleEnabled`, or a small
dedicated setter). `0/1` bypass detection.

### iOS
iOS is single-display Retina → auto ⇒ on (matches current mobile-perf intent).

## Files (anticipated)
- `layer1/SettingInfo.h` — `cartoon_sampling_dynamic`, `cartoon_sampling_max`
  (new indices, next free after 823); `metal_upscale` REC_b→REC_i (0..2).
- `swiftui/PyMOLViewer/Shared/MetalViewport.swift` — camera-settle observer +
  debounce; LOD compute; screen-change observer for upscale auto.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — helpers: current Å/px from
  view+fov+viewport; `setCartoonSampling(n)+rebuild`; upscale-auto decision.
- `layer1/SceneRender.cpp` / `RendererMetal` — resolve `metal_upscale==2` to the
  Swift-provided Retina flag when driving `_upscaleEnabled` (design detail for
  the plan: either Swift pushes the effective bool, or the core reads a
  Swift-set "display is retina" signal).

## Testing
- Unit-ish: Å/px formula vs known camera setups; bucket+hysteresis transitions.
- LOD: zoom in/out on 1ubq, 1hho, 1aon — sampling steps up/down at thresholds,
  no thrash at boundaries; rebuild latency within measured range; no mid-drag
  rebuild.
- Upscale auto: drag the window between a Retina and a non-Retina display →
  upscale flips; `0`/`1` override detection.
- Regression: `cartoon_sampling_dynamic off` + `metal_upscale 0/1` ⇒ identical to
  current master. Verify in the mac-vm-test VM (per standing instruction) plus
  host A/B.

## Open risks
- Å/px ↔ sampling calibration is empirical; buckets above are a starting point.
- Very large structures: whole-object high-sampling render cost (steady-state, not
  just rebuild) is unmitigated by design — bounded by `cartoon_sampling_max` auto
  cap; revisit only if it's a problem in practice.
- Detecting "camera settled" cleanly on an on-demand render loop needs a reliable
  camera-change hook; if none exists, poll the view hash on the existing redraw.
