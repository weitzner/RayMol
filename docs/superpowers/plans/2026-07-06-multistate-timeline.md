# Multi-state timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the movie timeline handle multi-state objects (NMR ensembles / MD trajectories) non-destructively, represent them correctly, and let users author ensemble movies (per-object state sweeps) that compose with camera motion + scenes.

**Architecture:** State is resolved per frame. Bare ensemble + empty timeline → author no `mset` (core plays it via `count_frames` fallback). When a movie is authored, multi-state objects sweep via **per-object `mview state` tracks** (`PyMOLObject.cpp:1000` applies per-object `ViewElem.state` to each object's own `state` setting at render), so objects of different lengths animate independently. A first-class `.states` timeline clip gives explicit control; with no clip, all multi-state objects auto-sweep across the movie span.

**Tech Stack:** Python (`pymol.cmd` movie API: `mset`/`mview`/`count_states`), Swift/SwiftUI (`PyMOLEngine`, `TimelinePanel`, `TransportBar`), headless PyMOL for Python tests, iOS simulator + macOS VM (tart/mac-vm-pool) for functional tests, `devicectl` for device deploy.

## Global Constraints

- Branch: `claude/raymol-timeline-movies-ltr0d6` (stacks on the timeline feature; do NOT branch off master).
- Never write `mset '1 xN'` over a multi-state object without either a user-authored movie (camera/scene item) or an explicit states clip; "Reset to plain ensemble" (`mview reset; mset ''; rewind`) must always restore all N models.
- State interpolation requires BOTH bracketing keyframes flagged (`View.cpp:1140`) — always store state at both endpoints of a sweep, never rely on one flagged + one unflagged.
- iOS/iPhone/iPad touch targets unchanged by this work; macOS unaffected except the new UI.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Verify claims by running/observing; never assert "works" without evidence (screenshot / decoded MP4 / assertion output).

## File Structure

- `modules/pymol/appkit_movie.py` — rewrite `rebuild()`; add `_multistate_objects()`, `_emit_state_sweep()`, `reset_ensemble()`. The single Python choke point.
- `testing/tests/jira/multistate_timeline.py` — headless PyMOL tests for the rebuild logic (state reachability, non-destructive, per-object independence).
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `TimelineItem.Kind.states`, `StatesSpec`, span-aware `itemFrames()`/`timelineTotalFrames`, `rebuildMovie()` serialization, `appendStatesClip()`, `setItemPinnedState()`, `resetToPlainEnsemble()`, expose `maxStateCount`/`multiStateObjects`.
- `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` — "N models" header, gutter state strip, ensemble-clip node + long-press editor, "Play models" composer preset, ruler-unit toggle, reset affordance.
- `swiftui/PyMOLViewer/Panels/TransportBar.swift` — "model k / N" counter for a bare ensemble.
- `/private/tmp/.../scratchpad/multistate_frames_test.swift` — standalone Swift test of the span-aware frame math (compiled with `swift`, no Xcode), mirroring the CartoonLOD precedent.

---

## Phase 1 — Python core (headless-testable)

### Task 1: `_multistate_objects()` + `_emit_state_sweep()` helpers

**Files:**
- Modify: `modules/pymol/appkit_movie.py` (add after `_ease`, ~line 50)
- Test: `testing/tests/jira/multistate_timeline.py` (create)

**Interfaces:**
- Produces: `appkit_movie._multistate_objects(names=None) -> dict[str,int]` (enabled objects with >1 state → nstates); `appkit_movie._emit_state_sweep(obj, nstates, start, end, mode) -> None` (stores per-object state keyframes 1..N across [start,end] and interpolates that object's track).

- [ ] **Step 1: Write the failing test**

```python
# testing/tests/jira/multistate_timeline.py
from pymol import cmd, testing, appkit_movie

class TestMultistateTimeline(testing.PyMOLTestCase):

    def _make_ensemble(self, name, n):
        # Build an n-state object cheaply: fab a dipeptide, then copy state 1
        # into states 2..n so count_states(name) == n.
        cmd.fab('AG', name)
        for i in range(2, n + 1):
            cmd.create(name, name, 1, i)
        self.assertEqual(cmd.count_states(name), n)

    def test_multistate_objects_detects_counts(self):
        cmd.reinitialize()
        self._make_ensemble('nmr', 10)
        cmd.fab('A', 'mono')                      # single state
        d = appkit_movie._multistate_objects()
        self.assertEqual(d.get('nmr'), 10)
        self.assertNotIn('mono', d)               # 1-state excluded

    def test_emit_state_sweep_reaches_all_states(self):
        cmd.reinitialize()
        self._make_ensemble('nmr', 10)
        cmd.mset('1 x60')                         # 60-frame canvas
        appkit_movie._emit_state_sweep('nmr', 10, 1, 60, 'sweep')
        # Walk the movie; the object's own state must cover ~1..10.
        seen = set()
        for f in range(1, 61):
            cmd.frame(f)
            cmd.refresh()                          # apply ViewElem -> object state
            seen.add(cmd.get('state', 'nmr'))
        self.assertIn(1, seen)
        self.assertIn(10, seen)
        self.assertGreaterEqual(len(seen), 8)      # a real sweep, not frozen
```

- [ ] **Step 2: Run to verify it fails**

Run: `pymol -ckqy testing/testing.py --run tests/jira/multistate_timeline.py`
Expected: FAIL (`AttributeError: module 'pymol.appkit_movie' has no attribute '_multistate_objects'`).

- [ ] **Step 3: Implement the helpers**

```python
# in modules/pymol/appkit_movie.py, after _ease()

def _multistate_objects(names=None):
    """{objname: nstates} for objects with >1 coordinate state. `names` (list)
    restricts to those objects; None = every object in the session."""
    out = {}
    try:
        objs = names if names else cmd.get_object_list()
    except Exception:
        objs = []
    for o in (objs or []):
        try:
            ns = int(cmd.count_states(o))
            if ns > 1:
                out[o] = ns
        except Exception:
            pass
    return out


def _emit_state_sweep(obj, nstates, start, end, mode='sweep'):
    """Store per-object STATE keyframes so `obj` sweeps 1..nstates across movie
    frames [start,end], then interpolate that object's own track. Both endpoints
    are flagged (state=) so View.cpp interpolates the state channel; the per-object
    ViewElem sets the object's own `state` at render (independent of the mset and
    of other objects). mode: 'sweep' (1->N) or 'loop' (1->N->1)."""
    try:
        s = int(start); e = int(end); n = int(nstates)
        if e <= s:
            e = s + 1
        if mode == 'loop':
            mid = (s + e) // 2
            cmd.mview('store', object=obj, first=s,   state=1)
            cmd.mview('store', object=obj, first=mid, state=n)
            cmd.mview('store', object=obj, first=e,   state=1)
        else:
            cmd.mview('store', object=obj, first=s, state=1)
            cmd.mview('store', object=obj, first=e, state=n)
        cmd.mview('interpolate', object=obj)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))
```

- [ ] **Step 4: Run to verify it passes**

Run: `pymol -ckqy testing/testing.py --run tests/jira/multistate_timeline.py`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/appkit_movie.py testing/tests/jira/multistate_timeline.py
git commit -m "feat(movie): per-object state-sweep helpers for multi-state objects

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: State-aware `rebuild()` — non-destructive + per-object sweep + `reset_ensemble()`

**Files:**
- Modify: `modules/pymol/appkit_movie.py` (`rebuild`, ~304–350; add `reset_ensemble`)
- Test: `testing/tests/jira/multistate_timeline.py` (extend)

**Interfaces:**
- Consumes: `_multistate_objects`, `_emit_state_sweep` (Task 1).
- Produces: `appkit_movie.rebuild(spec_json)` now honoring `states` items + auto-sweep; `appkit_movie.reset_ensemble() -> None` (`mview reset; mset ''; rewind`). Spec item shapes:
  - camera: `{frame, cam:<uuid>, power, linear}`
  - scene: `{frame, scene:<b64>, power, linear}`
  - states clip: `{frame:<startFrame>, end:<endFrame>, states:1, objects:[names]|null, mode:"sweep"|"loop"|"lockstep"}`

- [ ] **Step 1: Write the failing tests**

```python
    # append to TestMultistateTimeline

    def test_rebuild_empty_authors_no_mset(self):
        cmd.reinitialize()
        self._make_ensemble('nmr', 10)
        appkit_movie.rebuild('[]')                 # empty timeline
        # No mset => movie length 0 => count_frames falls back to state count.
        self.assertEqual(cmd.count_frames(), 10)   # plays the ensemble untouched

    def test_rebuild_camera_only_does_not_collapse_ensemble(self):
        cmd.reinitialize()
        self._make_ensemble('nmr', 10)
        import json, base64
        spec = [{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0},
                {'frame': 60, 'cam': 'B', 'power': 0.0, 'linear': 0}]
        # No stored views for A/B is fine; we only assert state reachability.
        appkit_movie.rebuild(json.dumps(spec))
        seen = set()
        for f in range(1, cmd.count_frames() + 1):
            cmd.frame(f); cmd.refresh()
            seen.add(cmd.get('state', 'nmr'))
        self.assertGreaterEqual(len(seen), 8)      # auto-sweep, NOT frozen on 1
        self.assertIn(10, seen)

    def test_rebuild_two_ensembles_independent(self):
        cmd.reinitialize()
        self._make_ensemble('short', 5)
        self._make_ensemble('long', 40)
        import json
        spec = [{'frame': 1, 'states': 1, 'end': 80, 'objects': None, 'mode': 'sweep'}]
        appkit_movie.rebuild(json.dumps(spec))
        s_seen, l_seen = set(), set()
        for f in range(1, cmd.count_frames() + 1):
            cmd.frame(f); cmd.refresh()
            s_seen.add(cmd.get('state', 'short'))
            l_seen.add(cmd.get('state', 'long'))
        self.assertIn(5, s_seen)                   # short reaches its max
        self.assertIn(40, l_seen)                  # long reaches its max
        # short is not clamped to long's range; both cover their full range
        self.assertLessEqual(max(s_seen), 5)

    def test_reset_ensemble_restores_all_models(self):
        cmd.reinitialize()
        self._make_ensemble('nmr', 10)
        import json
        appkit_movie.rebuild(json.dumps([{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0}]))
        appkit_movie.reset_ensemble()
        self.assertEqual(cmd.count_frames(), 10)   # back to plain ensemble
```

- [ ] **Step 2: Run to verify they fail**

Run: `pymol -ckqy testing/testing.py --run tests/jira/multistate_timeline.py`
Expected: FAIL (`test_rebuild_camera_only_does_not_collapse_ensemble` sees frozen state 1; `reset_ensemble` missing).

- [ ] **Step 3: Rewrite `rebuild()` + add `reset_ensemble()`**

```python
def reset_ensemble():
    """Drop all movie authoring and rewind so a multi-state object plays its raw
    models again (count_frames falls back to the state count)."""
    try:
        cmd.mview('reset')
        cmd.mset('')
        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def rebuild(spec_json):
    """Rebuild the whole movie from the ordered Swift spec. Items:
      camera : {frame, cam:<uuid>, power, linear}
      scene  : {frame, scene:<b64>, power, linear}
      states : {frame:<start>, end:<endFrame>, states:1, objects:[..]|null, mode}
    State is resolved per frame: explicit states clips sweep their objects across
    their span; if a movie exists with NO states clip, every multi-state object
    auto-sweeps across the whole span (non-destructive default). Per-object
    `mview state` tracks make each object independent of the mset and of each
    other. When the spec is empty, author nothing (see reset_ensemble)."""
    import json, base64
    try:
        spec = json.loads(spec_json)
        if not spec:
            reset_ensemble()
            return
        cmd.mview('reset')
        total = max(2, max(int(it.get('end', it['frame'])) for it in spec))
        cmd.mset('1 x%d' % total)

        state_clips = [it for it in spec if it.get('states')]
        cam_scene = [it for it in spec if not it.get('states')]

        # Camera + scene keyframes on the global track.
        for it in cam_scene:
            f = int(it['frame'])
            power = float(it.get('power', 0.0))
            linear = int(it.get('linear', 0))
            cmd.frame(f)
            sc = it.get('scene')
            if sc:
                name = base64.b64decode(sc).decode('utf-8')
                cmd.scene(name, 'recall')
                cmd.mview('store', first=f, scene=name, power=power, linear=linear)
                # Preserve the scene's stored state for NON-swept objects: pin the
                # global state channel at this frame to whatever the recall set.
                try:
                    cmd.mview('store', first=f, state=int(cmd.get_state()))
                except Exception:
                    pass
            else:
                cam = it.get('cam')
                v = _views.get(str(cam)) if cam is not None else None
                if v:
                    cmd.set_view(v)
                cmd.mview('store', first=f, power=power, linear=linear)
        if cam_scene:
            cmd.mview('interpolate')

        # State sweeps (per-object tracks — independent, no clamping).
        if state_clips:
            for clip in state_clips:
                start = int(clip['frame']); end = int(clip.get('end', total))
                mode = str(clip.get('mode', 'sweep'))
                names = clip.get('objects')
                ms = _multistate_objects(names)
                if mode == 'lockstep':
                    # One global sweep to the max count; shorter objects clamp.
                    mx = max(ms.values()) if ms else 1
                    seq = ' '.join(str(int(1 + round((mx - 1) * (i - start) / max(1, end - start))))
                                   for i in range(start, end + 1))
                    cmd.mset(seq, start)   # overwrite that span of the mset
                else:
                    for obj, n in ms.items():
                        _emit_state_sweep(obj, n, start, end, mode)
        else:
            # Non-destructive default: auto-sweep every multi-state object across
            # the full movie so a camera/scene movie never freezes the ensemble.
            for obj, n in _multistate_objects().items():
                _emit_state_sweep(obj, n, 1, total, 'sweep')

        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))
```

- [ ] **Step 4: Run to verify they pass**

Run: `pymol -ckqy testing/testing.py --run tests/jira/multistate_timeline.py`
Expected: PASS (all tests, including the two-ensemble independence gate).

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/appkit_movie.py testing/tests/jira/multistate_timeline.py
git commit -m "feat(movie): state-aware rebuild — non-destructive + per-object sweeps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — Swift engine

### Task 3: `TimelineItem.Kind.states` + `StatesSpec`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:206-214`

**Interfaces:**
- Produces: `enum StatesMode: String { case sweep, loop, lockstep }`; `struct StatesSpec: Equatable { var objects: [String]?; var mode: StatesMode; var durationSeconds: Double }`; `TimelineItem.Kind.states(StatesSpec)`; `TimelineItem.pinnedState: Int?`.

- [ ] **Step 1: Extend the model**

```swift
enum StatesMode: String, Equatable { case sweep, loop, lockstep }
struct StatesSpec: Equatable {
    var objects: [String]? = nil          // nil = all multi-state objects
    var mode: StatesMode = .sweep
    var durationSeconds: Double = 4.0
}
struct TimelineItem: Identifiable, Equatable {
    enum Kind: Equatable { case camera; case scene(name: String); case states(StatesSpec) }
    let id: UUID
    var kind: Kind
    var transition: Transition
    var pinnedState: Int? = nil           // camera/scene: hold this model (opt-out of auto-sweep)
    init(id: UUID = UUID(), kind: Kind, transition: Transition = Transition(), pinnedState: Int? = nil) {
        self.id = id; self.kind = kind; self.transition = transition; self.pinnedState = pinnedState
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath build_mac_dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail`
Expected: `** BUILD SUCCEEDED **` (switch statements over `Kind` in TimelinePanel will error until Task 8 — if so, add a temporary `case .states: EmptyView()` and remove it in Task 8; note it here).

- [ ] **Step 3: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(timeline): TimelineItem.states kind + StatesSpec + pinnedState

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Span-aware `itemFrames()` + start/end pairs

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:1391-1405`
- Test: standalone Swift script (below)

**Interfaces:**
- Produces: `func itemSpans() -> [(start: Int, end: Int)]` (each item's inbound-transition start frame + its own span end; camera/scene end==start; states clip end = start + duration×fps). `itemFrames()` returns `itemSpans().map { $0.start }` (back-compat). `timelineTotalFrames` = max end.

- [ ] **Step 1: Write the failing standalone test**

```swift
// /private/tmp/.../scratchpad/multistate_frames_test.swift
// Mirror the pure math of itemSpans() and assert span accumulation.
func spans(_ items: [(secs: Double, dur: Double?)], fps: Double) -> [(Int, Int)] {
    var out: [(Int, Int)] = []; var acc = 0.0
    for (i, it) in items.enumerated() {
        let start = i == 0 ? 1 : max((out.last?.1 ?? 0) + 1, 1 + Int((acc + max(it.secs, 0.1)) * fps))
        if i > 0 { acc += max(it.secs, 0.1) }
        let end = it.dur != nil ? start + Int((it.dur! * fps).rounded()) : start
        out.append((start, end))
    }
    return out
}
let r = spans([(0, nil), (2, 4.0), (2, nil)], fps: 30)  // cam@1, states 4s clip, cam
assert(r[0] == (1,1))
assert(r[1].0 == 61 && r[1].1 == 61 + 120)   // clip spans 120 frames
assert(r[2].0 >= r[1].1 + 1)                  // next item starts after the clip
print("OK spans:", r)
```

- [ ] **Step 2: Run to verify it fails / then passes**

Run: `swift /private/tmp/.../scratchpad/multistate_frames_test.swift`
Expected first: assertion may pass immediately (it's a reference); its purpose is to lock the math you port into `itemSpans()`. Confirm `OK spans:` prints.

- [ ] **Step 3: Implement `itemSpans()` and rewire `itemFrames`/`timelineTotalFrames`**

```swift
func itemSpans() -> [(start: Int, end: Int)] {
    guard !timelineItems.isEmpty else { return [] }
    let fps = max(playback.movieFPS, 1)
    var out: [(Int, Int)] = []; var acc = 0.0
    for (i, it) in timelineItems.enumerated() {
        let start: Int
        if i == 0 { start = 1 }
        else { acc += max(it.transition.seconds, 0.1); start = max((out.last?.end ?? 0) + 1, 1 + Int((acc * fps).rounded())) }
        var end = start
        if case .states(let spec) = it.kind { end = start + max(1, Int((spec.durationSeconds * fps).rounded())) }
        out.append((start, end))
    }
    return out
}
func itemFrames() -> [Int] { itemSpans().map { $0.start } }
var timelineTotalFrames: Int { itemSpans().map { $0.end }.max() ?? 1 }
```

- [ ] **Step 4: Build (macOS) — SUCCEEDED. Commit.**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(timeline): span-aware itemSpans() for states clips

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `rebuildMovie()` serialization for states items + engine helpers

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:1412-1442` (+ new methods)

**Interfaces:**
- Consumes: `itemSpans()` (Task 4), `appkit_movie.rebuild`/`reset_ensemble` (Task 2).
- Produces: `func appendStatesClip(objects: [String]?, mode: StatesMode, seconds: Double)`; `func setItemPinnedState(_ id: UUID, _ state: Int?)`; `func resetToPlainEnsemble()`; `@Published var maxStateCount: Int`; `func multiStateObjects() -> [(String, Int)]`.

- [ ] **Step 1: Serialize states items in `rebuildMovie()`**

Replace the `switch it.kind` block so a states clip emits `{"frame":start,"end":end,"states":1,"objects":<json|null>,"mode":"…"}`, and camera/scene items append `,"state":<pinnedState>` when set. Full replacement:

```swift
let spans = itemSpans()
var parts: [String] = []
for (i, it) in timelineItems.enumerated() {
    let (start, end) = spans[i]
    let ease = it.transition.linear ? "\"power\":1.0,\"linear\":1" : "\"power\":0.0,\"linear\":0"
    switch it.kind {
    case .camera:
        var s = "{\"frame\":\(start),\"cam\":\"\(it.id.uuidString)\",\(ease)"
        if let ps = it.pinnedState { s += ",\"state\":\(ps)" }
        parts.append(s + "}")
    case .scene(let name):
        let b64 = Data(name.utf8).base64EncodedString()
        var s = "{\"frame\":\(start),\"scene\":\"\(b64)\",\(ease)"
        if let ps = it.pinnedState { s += ",\"state\":\(ps)" }
        parts.append(s + "}")
    case .states(let spec):
        let objs = spec.objects.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        parts.append("{\"frame\":\(start),\"end\":\(end),\"states\":1,\"objects\":\(objs),\"mode\":\"\(spec.mode.rawValue)\"}")
    }
}
```

Set `playback.frameCount = timelineTotalFrames` at the end (not `frames.last`).

- [ ] **Step 2: Add engine helpers**

```swift
func appendStatesClip(objects: [String]? = nil, mode: StatesMode = .sweep, seconds: Double = 4.0) {
    guard isReady else { return }
    timelineItems.append(TimelineItem(kind: .states(StatesSpec(objects: objects, mode: mode, durationSeconds: seconds))))
    rebuildMovie()
}
func setItemPinnedState(_ id: UUID, _ state: Int?) {
    guard let i = timelineItems.firstIndex(where: { $0.id == id }) else { return }
    timelineItems[i].pinnedState = state; rebuildMovie()
}
func resetToPlainEnsemble() {
    guard isReady else { return }
    timelineItems.removeAll()
    runPython("from pymol import appkit_movie as _am\n_am.reset_ensemble()")
    playback.frameCount = max(multiStateObjects().map { $0.1 }.max() ?? 1, 1)
    playback.currentFrame = 1
}
```

Also handle `.state` serialization in the Python `rebuild` cam/scene branch: read `it.get('state')` and, when present, `cmd.mview('store', first=f, state=int(...))` for that object set — but since camera/scene pins affect the GLOBAL channel, store it globally. Add to Task 2's cam/scene loop:
```python
            ps = it.get('state')
            if ps is not None:
                cmd.mview('store', first=f, state=int(ps))
```
(Add this line now and amend Task 2's commit if already made; otherwise fold in.)

- [ ] **Step 3: Wire `maxStateCount` / `multiStateObjects()`**

`nstate` per object is already parsed in the OBJPANEL feedback (`PyMOLEngine.swift:1099`, into `ObjectEntry.stateCount`). Add:
```swift
func multiStateObjects() -> [(String, Int)] { objects.filter { $0.stateCount > 1 }.map { ($0.name, $0.stateCount) } }
var maxStateCount: Int { objects.map { $0.stateCount }.max() ?? 1 }
```

- [ ] **Step 4: Build (macOS) — SUCCEEDED. Commit.**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift modules/pymol/appkit_movie.py
git commit -m "feat(timeline): serialize states clips + pinned state; engine helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — Swift UI (TimelinePanel + TransportBar)

### Task 6: "N models" header + gutter state strip for a bare ensemble

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` (header text ~236; ruler ~318)

- [ ] **Step 1:** In the header, when `engine.timelineItems.isEmpty && engine.maxStateCount > 1`, show `"\(engine.maxStateCount) models"` instead of "Empty".
- [ ] **Step 2:** In the ruler view, when the same condition holds, overlay a ~10pt strip along the gutter bottom: for `maxStateCount <= 40` draw evenly spaced ticks with the tick nearest `playback.currentFrame` highlighted; else a continuous progress band at `currentFrame/frameCount`. Non-interactive (scrub via the existing playhead).
- [ ] **Step 3:** Build (macOS) — SUCCEEDED.
- [ ] **Step 4:** Commit `feat(timeline): represent a bare ensemble ("N models" + gutter strip)`.

### Task 7: Ensemble-clip node + long-press editor

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` (item rendering ~426-477)

- [ ] **Step 1:** Add a `case .states(let spec):` to the item-lane node switch (remove the temporary stub from Task 3). Render a rounded block spanning `spans[i].start…end` (px = frames×pxPerSecond/fps), labeled `spec.objects?.count == 1 ? name : "\(count) models"`; draw ≤~12 decimated internal guide ticks.
- [ ] **Step 2:** Add a `case .states` to `itemMenu` (long-press): mode picker (Sweep / Loop / Lockstep → `engine` mutate spec + `rebuildMovie()`), duration stepper, objects (All / pick from `multiStateObjects()`).
- [ ] **Step 3:** Build (macOS) — SUCCEEDED.
- [ ] **Step 4:** Commit `feat(timeline): ensemble-clip node + long-press editor`.

### Task 8: "Play models" composer preset

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` (composer ~574-618; `composerKind` ~61)

- [ ] **Step 1:** Add a `"Play models"` entry to the composer kind Menu; when `composerKind == "states"`, `appendComposer()` calls `engine.appendStatesClip(objects: nil, mode: .sweep, seconds: <duration chip>)`. Only offer it when `engine.maxStateCount > 1` (else hide, to avoid clutter on single-state scenes).
- [ ] **Step 2:** Build (macOS) — SUCCEEDED.
- [ ] **Step 3:** Commit `feat(timeline): "Play models" composer preset`.

### Task 9: Ruler-unit toggle + "Reset to plain ensemble"

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` (header)

- [ ] **Step 1:** When `timelineItems.isEmpty && maxStateCount > 1`, show a small Seconds⇄Models unit toggle (default Models); it only relabels the ruler ticks (states vs seconds). When items exist, force Seconds.
- [ ] **Step 2:** Add a "Reset to plain ensemble" affordance (menu item on the trash/… control, enabled when `maxStateCount > 1`) → `engine.resetToPlainEnsemble()`.
- [ ] **Step 3:** Build (macOS) — SUCCEEDED.
- [ ] **Step 4:** Commit `feat(timeline): ruler-unit toggle + reset-to-plain-ensemble`.

### Task 10: TransportBar "model k / N" counter

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/TransportBar.swift:192-201`

- [ ] **Step 1:** When `engine.timelineItems.isEmpty && engine.maxStateCount > 1`, render `"model \(currentFrame) / \(frameCount)"` (still width-reserved); else keep `"\(currentFrame) / \(frameCount)"`. (TransportBar reads `engine` — already an `@EnvironmentObject`.)
- [ ] **Step 2:** Build (macOS) — SUCCEEDED.
- [ ] **Step 3:** Commit `feat(timeline): model counter for a bare ensemble`.

---

## Phase 4 — Verification + deploy

### Task 11: iOS simulator functional verification

- [ ] Build the iOS sim target; boot an iPhone sim; `simctl install`+`launch`.
- [ ] Drive via `PYMOL_AUTOCMD`/command line: `fetch 1d3z, async=0` → assert transport reads "model 1 / 10" and ruler shows models (screenshot).
- [ ] Append a camera keyframe → step frames; assert the molecule's model changes (viewport-diff harness) and counter did NOT drop to "1 / 2".
- [ ] "Play models" clip → verify block renders; play → models cycle.
- [ ] Commit any sim-only fixes; note results.

### Task 12: macOS VM functional verification (mac-vm-pool)

- [ ] Acquire a VM; hot-swap the macOS build; `fetch 1d3z, async=0`.
- [ ] Repeat the reachability + non-destructive gates; **export an MP4 and decode it** (assert coordinates change frame-to-frame — the C1/C2/export gate).
- [ ] Two ensembles (short+long) sweep independently; `all_states` on → warn path; "Reset to plain ensemble" → back to N models.
- [ ] Capture screenshots; release the VM.

### Task 13: Deploy to physical iPhone

- [ ] `xcodebuild` device build (DEVELOPMENT_TEAM=VT99UQUQ89); `devicectl device install` + `launch`.
- [ ] Confirm the app launches and a fetched NMR shows "model k / N"; hand off to the user.

---

## Self-Review

- **Spec coverage:** non-destructive empty (Task 2 `test_rebuild_empty_authors_no_mset`), per-frame state / no-collapse (Task 2 `test_rebuild_camera_only_does_not_collapse_ensemble`), per-object independence (Task 2 `test_rebuild_two_ensembles_independent`), scene-state (Task 2 scene branch stores `state`), auto-sweep default (Task 2 else-branch), states clip UI (Tasks 7-8), representation (Task 6), units/reset (Task 9), counter (Task 10), export gate (Task 12), all_states warning (Task 12 — surfaced in UI via Task 7 long-press "objects"; a dedicated warning is folded into Task 8's append when a targeted object has all_states on — ADD: in `appendStatesClip`, if any targeted object has `all_states` on, set a `@Published var stateSweepWarning` the panel shows). Lockstep mode (Task 2 lockstep branch + Task 7 mode picker). Large-trajectory decimation (Task 7 ≤12 guide ticks; duration-driven frame count in `itemSpans`).
- **Placeholder scan:** none — every code step has concrete code; UI tasks name exact files/anchors and the mutation. (UI steps intentionally describe the SwiftUI node rather than paste 100-line view bodies; each is a single cohesive edit at a named anchor.)
- **Type consistency:** `StatesSpec`/`StatesMode`/`.states` used identically across Tasks 3/5/7/8; `itemSpans()` returns `(start,end)` used in Tasks 5/7; `appendStatesClip`/`resetToPlainEnsemble`/`multiStateObjects`/`maxStateCount` defined in Task 5 and consumed in 6-10; Python spec keys (`end`,`states`,`objects`,`mode`,`state`) match between Task 2 (`rebuild`) and Task 5 (serializer).
