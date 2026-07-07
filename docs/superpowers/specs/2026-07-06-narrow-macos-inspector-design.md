# Narrow the macOS right inspector

**Date:** 2026-07-06
**Branch:** `claude/raymol-timeline-movies-ltr0d6`
**Status:** approved (design), macOS-first implementation

## Problem

The macOS right inspector column is `inspectorSwitcher.frame(width: 440)`
(`ContentView.swift:433`). Before the timeline feature it was **300pt**; git
shows it climbed 300 → 360 → 400 → 440, and the last two bumps
(`ed4d282e6`) were *only* to stop the Movie-tab transport counter from clipping.
It now reads as much wider than before on every tab, even Objects/Scenes/Display
which were happy at ~300.

## Root cause

The panel is wide **solely** because of the compact/`inTimeline` transport row
in `TransportBar.swift`, which needs ~420pt on one line:

| piece | width |
|---|---|
| transport cluster (4× icon @40 + play @44, spacing 2) | ~212 |
| loop button | 40 |
| fps menu (`fpsMenuTight`, "30 fps") | ~48 |
| counter reserved (`(digits*2+3)*7.4`, 3 digits) | ~67 |
| inter-group spacing (6×4) + horizontal padding (12×2) | ~48 |
| **total** | **~420** |

macOS renders these controls denser/wider than iOS, which is why 400 clipped and
440 was chosen.

## Decision

**Narrow fixed width + fit the transport** (chosen over resizable divider and
per-tab adaptive width — simplest, predictable, no width jumps).

### 1. Width
- macOS: `inspectorSwitcher.frame(width: 440)` → **340** (`ContentView.swift:433`).
  - 340, not the old 300, because the A/S/H/L/C rep boxes were recently enlarged
    22→38 (commit `89d9261cc`), adding ~80pt of fixed width to each Objects row;
    at 300 object names truncate hard. At 340 the Objects row leaves ~90pt for the
    name. 340 also matches the Theme Studio column (already 340) for a consistent
    right edge.

### 2. Fit the Movie transport into 340 (macOS only)
Shrink the `inTimeline` compact transport row **on macOS only** (platform
constants), keeping **fps + loop in the controls row** (an earlier explicit
request). iPhone/iPad transports are touch-driven and stay at their current
sizes — the shrink must NOT touch them.

- transport icon buttons 40→~30 wide, play/pause 44→~34 (macOS is pointer-driven).
- `fpsMenuTight`: show a compact accent number (drop the " fps" text) and use a
  borderless/chrome-free menu on macOS so the native pull-down border doesn't add
  width.
- tighten inter-group spacing 6→4 and horizontal padding 12→8 on macOS.

Estimated macOS single-row width at these sizes: ~310pt → fits 340 with margin.

### 3. Fallback
macOS control widths are hard to predict, so **verify live in the VM at 340**.
If the single row still can't fit cleanly, wrap the transport to two rows *inside
the narrow inspector only* — never re-widen the panel.

## Scope

- `swiftui/PyMOLViewer/Shared/ContentView.swift` — macOS inspector width (one number).
- `swiftui/PyMOLViewer/Panels/TransportBar.swift` — macOS-only compact-row sizing.
- Objects/Scenes/Display already fit 340. iPhone unaffected.

### iPad (deferred, not in this pass)
iPad mirrors the width at `rightW: CGFloat = 440` (`ContentView.swift:1248`). It
stays 440 for now: its touch-sized transport needs the room on one row, and
narrowing it to 340 requires wrapping the transport to two rows — a change best
verified on the iPad simulator as a quick follow-up rather than shipped
unverified here.

## Verification

- Build macOS, hot-swap into the disposable macOS VM.
- Load a structure (`fab ACDEFGHIK, m`), open the Movie tab, confirm the transport
  (cluster + loop + fps + counter) renders with no clipping at 340pt.
- Switch through Objects / Scenes / Display and confirm none clip and object names
  remain legible.
