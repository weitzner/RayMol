# Multi-state objects in the movie timeline

**Date:** 2026-07-06
**Branch:** `claude/raymol-timeline-movies-ltr0d6` (stacks on the timeline feature, PR #85)
**Status:** approved (design) — implement

## Problem

The unified movie timeline mishandles multi-state objects (NMR ensembles, MD
trajectories). Confirmed by reproduction in a macOS VM with 1d3z (10 NMR models):

1. **Destructive.** A bare ensemble plays "1 / 10", but the instant a camera
   keyframe or scene marker is added, `rebuild()` lays `mset '1 xN'` and every
   frame collapses to **state 1** — the models become unreachable (counter drops
   to "1 / 2").
2. **No representation.** A freshly loaded 10-model ensemble shows "Empty" with a
   0–10 s seconds ruler that has nothing to do with its 10 frames.
3. **No authoring.** The composer offers only Camera Roll / Camera Rock — no way
   to build an ensemble movie in the unified timeline.

## Root cause

PyMOL shares **one** 1-based movie frame index. `mset` maps each frame → a
coordinate state; camera keyframes (`mview`) live on the same axis.
`rebuild()` ([appkit_movie.py:330](../../../modules/pymol/appkit_movie.py)) hardcodes
`cmd.mset('1 x%d' % total)` — pinning every frame to state 1.

### Verified core mechanics (these constrain the design)

- **State interpolation needs BOTH endpoints flagged.** `View.cpp:1140`:
  `state_flag = first->state_flag && last->state_flag`. So state cannot be an
  opt-in "pin on one keyframe" — a bare (unflagged) camera keyframe between two
  state waypoints breaks interpolation and the gap falls back to the mset. State
  must be resolved **per frame**, not left to interpolate across mixed keyframes.
- **Two state channels exist:**
  - **Global** — the `mset` (and the global movie `ViewElem`, `Movie.cpp:987`).
    Objects with no movie track of their own follow it and clamp to their own max.
  - **Per-object** — `mview store, object=<name>, state=k` stores state into that
    object's *own* `ViewElem` (`PyMOLObject.cpp:250`), and at render
    `ObjectPrepareContext` applies it to that object's **own** `state` setting
    (`PyMOLObject.cpp:1000`: `SettingSet_i(I->Setting.get(), cSetting_state, …)`).
    So each object can display an independent state at the same frame, and it
    serializes into `.pse`.
- **`count_frames()` falls back to max state count when no `mset` exists**
  (`Scene.cpp` SceneCountFrames) — so a bare multi-state object is playable with
  zero movie authored. The non-destructive default is therefore *literally to do
  nothing* to the movie on load.
- **Scenes stored at a state are suppressed once a movie is defined**
  (`Scene.cpp:680`: recall sets global state only if `!MovieDefined`). So a
  scene's stored state must be written into the state channel at its frame.

## Design

Chosen scope (user): **safe fix + first-class ensemble clip, in one pass.**

### Data model (`PyMOLEngine.TimelineItem`)

Extend `Kind` to `{ camera, scene(name), states(StatesSpec) }`.

```
StatesSpec = {
  objects: [String]?      // nil = all enabled multi-state objects
  mode: .sweepSync         // each object sweeps its full range over the clip
      | .lockstepFrame     // one global mset, shorter objects clamp/hold
      | .loop              // sweepSync then reverse (ping-pong)
  durationSeconds: Double  // clip length; independent of model count
}
```

- Camera/scene items stay **zero-width points**; a states clip occupies a
  **span** `[startFrame, endFrame]`.
- `itemFrames()` / `timelineTotalFrames` accumulate spans (not only transition
  gaps): a camera/scene contributes its inbound transition; a states clip
  contributes its inbound transition **plus** its own span.

### `rebuild()` — state resolved per frame (the correctness core)

Rewrite so state is never left to interpolate across mixed keyframes:

1. **Empty timeline → author no `mset` at all.** Bare multi-state objects keep
   their implicit `count_frames()` = state-count playback. (Fixes bug #1's root:
   the destructive write never happens without user intent.)
2. **Total frames** = from item spans (§ data model). A states clip's span =
   `round(durationSeconds × fps)`.
3. **Per targeted multi-state object, emit a per-object state track:** across the
   clip span, `mview store, object=<obj>, first=f, state=k` at strided frames so
   the object sweeps `1..Nobj` over the clip's duration, then
   `mview interpolate, object=<obj>`. In `.sweepSync` every object covers its
   full range over the same span (independent, no clamping); `.loop` mirrors;
   `.lockstepFrame` instead writes a state-sweeping **global** `mset` and no
   per-object tracks (shorter objects clamp — the rare absolute-frame case).
4. **Camera / scene keyframes** are emitted on the **global** `mview` track
   carrying only camera (and `scene=` for scene items). A scene item that was
   stored at a specific state writes that state into the global mset at its frame
   so recall and movie agree (fixes `Scene.cpp:680` suppression).
5. **Base `mset`:** `1 xTOTAL` as the substrate for camera frames; per-object
   state tracks override each swept object's state at render, so the "everything
   is state 1" collapse cannot happen for swept objects.
6. **Non-destructive default (no explicit clip):** when a movie is authored
   (any camera/scene item) and multi-state objects are present but NO states clip
   targets them, **auto-emit a per-object sweep track for every multi-state
   object across the full movie span**. This is what "adding a camera keyframe
   never collapses the ensemble" means operationally — the models keep cycling
   under the camera. An explicit states clip **overrides** this (it defines the
   span / mode / object subset); a per-item pinned state opts one object out
   (holds that model).
6. `mview interpolate` (global, camera) + per-object interpolates; `rewind`.

This is the desktop-PyMOL `add_state_sweep`/`add_roll` combination, generalized to
per-object tracks.

### UI (`TimelinePanel` / `TransportBar`)

- **Bare ensemble on load** (max nstate > 1, no items): header reads **"N models"**
  (never "Empty"); a thin **state strip in the ruler gutter** (~10 pt) — discrete
  ticks for ≤ ~40 states, a continuous band above that; transport reads
  **"model k / N"**. No `mset` authored. Strip is driven by the live
  `count_frames()` poll (not a cached snapshot) so it tracks object add/remove.
- **Ensemble clip:** a labeled draggable block (`"1d3z · 10 models"`, or
  `"2 objects"`), width = its duration, with **decimated** internal ticks (never
  one per model — a 2000-frame MD shows a block + "2000 frames", a few guides).
  Long-press: mode (Sweep-sync / Loop / Lockstep), objects (all / pick),
  duration. Camera diamonds + scene chips layer over it in the same single lane.
- **Composer:** add a **"Play models"** preset beside Roll/Rock that appends a
  states clip (default: all multi-state objects, `.sweepSync`, ~4 s).
- **Ruler units:** seconds once any timed item exists; frames/models for a bare
  ensemble, with a Seconds⇄Models toggle. Counter always matches the ruler
  ("model k / N" for a lone ensemble, "t / total s" once multiple objects or
  camera motion are present, since per-object model numbers diverge).
- **"Reset to plain ensemble":** one tap → `mview reset; mset ''; rewind` — always
  one action back to all-N-models playback.

### Multi-object handling (the key question)

- **Same model count:** one sweep drives all together (identical per-object tracks).
- **Different counts:** `.sweepSync` gives **each object its own per-object state
  track**, each sweeping its full `1..Nobj` over the clip — so a 10-model NMR and
  a 200-frame MD both complete over the same 8 s, independently, **no clamping or
  freezing**. `.lockstepFrame` is the opt-in absolute-frame mode (shorter clamps).
- **Single-state objects** in the mix are simply not targeted (no track) and hold
  their one state.

### Guardrails (from the adversarial critique)

- Never write `mset '1 xN'` over a multi-state object without a user-authored
  states clip or an explicit camera/scene movie; the "Reset to plain ensemble"
  affordance is always present.
- **`all_states` overlay:** if on for an object a clip would sweep, warn/offer to
  turn it off (else playback looks frozen — the object shows every model at once).
- **Large trajectories:** decimate ticks; the clip's frame count comes from
  `duration × fps` with striding, never from the model count directly.

## Verification (must pass — live AND exported)

Run on the iOS simulator (iPhone), then the macOS VM; deploy to the physical
iPhone last.

1. Load 10-model NMR → transport "1 / 10", ruler = models (not a 0–10 s empty
   strip), **no `mset` authored** (assert movie length 0 / mset empty).
2. Add a camera keyframe **between** two sweep waypoints → all 10 models still
   reachable while the camera moves (the C1/C2 regression gate — step frames,
   assert coordinates change per model).
3. **Export MP4 and decode it** → coordinates change frame-to-frame; not frozen on
   model 1 (assert on the file, not just the live poll).
4. Two ensembles of different lengths (10-model NMR + 200-frame MD), `.sweepSync`
   → both cycle their full range over the clip, neither frozen; `.lockstepFrame`
   → NMR holds at model 10 while MD continues (documented behavior).
5. 2000-frame MD → 8 s clip plays smoothly, seconds ruler stays legible, no
   per-frame diamond storm.
6. Scene stored at model 7 → recalling it in the movie shows model 7.
7. `all_states` on → sweeping warns/offers to disable; not silently frozen.
8. iPhone bottom sheet → "model k / N" counter, legible non-interactive state
   band, scrub via playhead.
9. "Reset to plain ensemble" → all N models one tap back.

## Scope / files

- `modules/pymol/appkit_movie.py` — rewrite `rebuild()` (per-frame state, per-object
  tracks, non-destructive empty case, scene-state, duration decoupling); helpers
  for state-clip mset/mview emission. Unit-testable headless.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `TimelineItem.Kind.states`,
  `StatesSpec`, span-aware `itemFrames()`/`timelineTotalFrames`, `rebuildMovie`
  serialization, expose per-object state counts + max nstate.
- `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` — clip rendering, gutter state
  strip, "N models" header, "Play models" preset, long-press options, ruler-unit
  toggle, "Reset to plain ensemble".
- `swiftui/PyMOLViewer/Panels/TransportBar.swift` — "model k / N" counter for a
  bare ensemble.

Out of scope (documented deferrals): per-object *camera* motion tracks; a manual
per-frame state editor.
