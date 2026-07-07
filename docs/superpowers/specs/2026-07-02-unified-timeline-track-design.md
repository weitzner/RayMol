# Unified single-track timeline with transitions

Date: 2026-07-02
Branch: `claude/raymol-timeline-movies-ltr0d6` (PR #85)

## Goal

Collapse the Camera + Scenes lanes into ONE lane holding both object kinds
(camera keyframes = diamonds, scenes = rounded chips) joined by **transitions**
(duration + easing) that are configurable on long-press. This also delivers
per-segment easing (the old global Smooth/Linear goes away).

## Decisions (brainstorm)

1. **Timing = sequence / ripple.** Objects are an ordered chain; each transition's
   duration sets the gap to the next object; movie length = Σ durations. Editing a
   transition (or add/delete/reorder) ripples later objects.
2. **Layout = proportional on a time ruler.** Objects sit at their cumulative time;
   the transition is the gap between them (long-press to configure).
3. **Reorder by dragging** an object past a neighbor.
4. **Default transition = 2 s, smooth.** Duration edited via a **preset menu**
   (0.5 / 1 / 2 / 5 / 8 s) + Smooth/Linear.

## Architecture

### Model — Swift is the source of truth

```
struct TimelineItem: Identifiable, Equatable {
    let id: UUID
    enum Kind: Equatable { case camera(view: [Float]); case scene(name: String) }
    var kind: Kind
    var transition: Transition        // the transition INTO this item (item[0]'s is ignored)
}
struct Transition: Equatable { var seconds: Double; var linear: Bool }   // 2.0, false = default
@Published var timelineItems: [TimelineItem] = []
```

- Frame of `item[i]` = `1 + round(Σ_{j≤i} item[j].transition.seconds · fps)` with
  `item[0]` at frame 1 (its transition ignored). Total frames = last item's frame.
- `cameraKeyframes:[Int]` / `sceneMarkers` are RETIRED (folded into `timelineItems`).

### Rebuild the core from the list (on every edit)

`appkit_movie.rebuild(spec_json)` where `spec_json` = ordered
`[{frame, view:[18]|null, scene:str|null, power, linear}]`:
- `mview reset`; `mset '1 x<total>'`.
- For each: `cmd.frame(f)`; camera → `set_view(view)`, scene → `scene(name,'recall')`;
  then `mview store, first=f[, scene=name], power=<0|1>, linear=<0|1>` (per-keyframe
  easing from the transition INTO it); finally `mview interpolate` (fill, keeping
  per-keyframe powers) + `rewind`. (Validate per-keyframe power on the host first;
  fall back to per-segment `reinterpolate first=..,last=..` if needed.)

Swift `rebuildMovie()`: compute frames, serialize items (base64 scene names),
run `rebuild`, set `playback.frameCount = total`.

### Engine ops (all end with `rebuildMovie()`)

- `captureCameraItem()` — append `.camera(get_view)` + default transition.
- `appendSceneItem(name)` — append `.scene(name)` + default transition.
- `moveItem(from:Int, to:Int)` — reorder.
- `deleteItem(_ id)` — remove.
- `setTransition(_ id, seconds:, linear:)` — edit one transition.
- `seekToItem(_ id)` — `cmd.frame(itemFrame)`.
- `appendTemplate` (composer) now appends ITEMS (roll → N camera items with default
  transitions; scenes → scene items; state → unchanged length-only, no items).
- `clearMovie` empties `timelineItems`.

### UI — one lane on the ruler (`TimelinePanel`)

Replace `cameraLane` + `scenesLane` with one `itemLane(width:)`:
- Render each item at `xFor(frame)`: camera → diamond, scene → labeled chip.
- Between adjacent items, a **transition connector** (thin bar + "2s · smooth"
  label) centered in the gap. Long-press → a config popover: duration preset menu
  (0.5/1/2/5/8 s) + Smooth/Linear → `engine.setTransition`.
- **Tap** item → `seekToItem`. **Long-press** item → menu (scene: recall / reset /
  rename / delete; camera: recall / delete → `deleteItem`). **Drag** item past a
  neighbor → `moveItem` (reorder; release recomputes).
- Palette (source scenes) unchanged → appends a scene item. `◆` capture →
  `captureCameraItem`. Composer → appends items.

## Edge cases

Empty list → empty-state hint; first item at frame 1 (no inbound transition).
One item → no transitions. Reorder is O(n) reindex + one rebuild. Ripple: any
edit recomputes all frames + one rebuild. Scene names base64-safe into Python.

## Non-goals

Free absolute-time dragging (timing is via transitions). A dedicated States track.
Nested/expandable template groups (a template just appends its items).

## Testing

Host (MCP): build a list (camera + scene items, mixed easing), verify frames and
that per-segment easing differs (smooth vs linear midpoints). Sim: unified lane
renders diamonds+chips with transition labels; long-press a transition changes
its duration (ripples) + easing; reorder; append templates decompose into items.
Then deploy to iPhone.
