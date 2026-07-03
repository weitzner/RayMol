# Timeline in the right panel + expandable bottom dock (macOS / iPad)

Date: 2026-07-03
Branch: `claude/raymol-timeline-movies-ltr0d6` (PR #85)

## Goal

On macOS and iPad, make the right inspector panel host the Timeline (like the
iPhone Movie tab), with an **Expand** button that additionally docks the full
timeline at the bottom (the current wide rendering). The bottom dock is
independent of the inspector tab (you can switch to Scenes/Objects while it
stays open) and has its own Close button. iPhone is unchanged.

## Decisions (approved)

1. **Expand = toggle.** The compact panel's Expand button opens the bottom dock
   and, tapped again, collapses it; it shows an active state while open. The
   bottom dock also has its own ✕ Close.
2. **iPad replaces the takeover.** iPad drops the current full-screen timeline
   takeover and uses the same right-panel + bottom-dock flow as macOS, so the
   inspector stays usable. iPhone keeps its Movie-tab-is-the-timeline flow.

## Architecture

Two synced views of ONE model (`engine.timelineItems`); `engine.timelineMode`
now means "the bottom dock is open".

- **Compact (right inspector "Movie" tab):** `TimelinePanel(showsDone: false,
  onExpand: { engine.timelineMode.toggle() })` at the inspector width (~360pt).
  Mimics the iPhone bottom panel; other tabs still selectable; state persists.
- **Expanded (bottom dock):** `TimelinePanel(showsDone: true)` (Close →
  `timelineMode = false`) docked in a VStack under the viewport, gated on
  `engine.timelineMode`, on BOTH macOS and iPad. Independent of `inspectorTab`.

### `TimelinePanel`
- New `var onExpand: (() -> Void)? = nil`. When set, the header shows an Expand
  button (`arrow.up.left.and.arrow.down.right`), highlighted when
  `engine.timelineMode` is true (dock open). `showsDone` still gates Close.

### `ContentView`
- Right inspector `case .movie` (`inspectorSwitcher`): `MoviePane()` →
  `TimelinePanel(showsDone: false, onExpand: …toggle timelineMode…)`.
- iPad dispatch: remove the `engine.timelineMode && !isPhone → iosTimelineLayout`
  branch; iPad always uses `iPadMacStyleLayout`. Delete the now-unused
  `iosTimelineLayout` + `exitTimeline`.
- `iPadMacStyleLayout`: dock `TimelinePanel()` below `viewportView` (Divider +
  panel) when `engine.timelineMode`, in both landscape (left column) and
  portrait (above the bottom inspector). Mirrors the macOS body (line ~394).
- macOS body already docks the bottom panel on `timelineMode` (keep). The
  clapperboard toolbar / Timeline menu keep toggling the dock.

## Edge cases

- Both views editable at once (duplicated) — same `@Published` source keeps them
  in sync. Independent per-view `@State` (zoom, drag) is fine.
- Compact fits ~360pt (iPhone fits ~390pt; all sections retained).
- Empty timeline: compact shows the empty hint; Expand still opens an (empty)
  dock so the user can author there too.

## Non-goals

Resizable bottom-dock height; a separate States track; portrait iPad getting a
distinct layout beyond docking above the inspector.

## Testing

macOS VM: Movie tab shows the compact timeline; Expand docks the full panel at
the bottom; switch to Scenes tab — dock stays; ✕ Close collapses it; Expand
button reflects open/closed. iOS sim: iPhone Movie tab unchanged; iPad sim
(if available) mirrors macOS. Both targets build.
