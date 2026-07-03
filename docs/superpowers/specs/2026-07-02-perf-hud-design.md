# Perf debug HUD overlay — design

Date: 2026-07-02
Status: approved (design), pending spec review
Related: adaptive cartoon LOD (PR #95). A live debug HUD for tuning LOD + watching render cost.

## Overview

A command-line-toggled on-screen overlay showing live rendering metrics (dynamic
LOD, triangle count, CPU/GPU memory, FPS, render-state flags), so LOD behavior
and performance can be introspected on-device and on the Mac without external
tools. Debug/dev tool — not shown in exports, not a full profiler.

## Activation

New setting **`metal_perf_hud`** (global bool, default **false**, next free idx
826). `set metal_perf_hud, 1` shows it, `,0` hides it. Read in the Swift layer
(the app already polls settings) and gates the overlay's visibility.

## Rendering

A **SwiftUI overlay** (`PerfHUDView`) pinned top-left over the `MetalViewport`,
monospaced text on a semi-transparent rounded background, refreshed ~3×/s via a
timer + updated in `draw(in:)`. Inlined into an existing view file (ContentView
or the MetalViewport host) to avoid Xcode pbxproj surgery. Cross-platform
(macOS + iOS). Not part of the offscreen/export render path (by design).

## Metrics + sources

- **LOD:** `cartoon_sampling` (live value the dynamic system writes), Å/px,
  current bucket, effective ceiling, `cartoon_sampling_dynamic` on/off. Å/px and
  the effective ceiling are computed in `PyMOLEngine.applyDynamicCartoonSampling`;
  store the last-computed values on a published object rather than recomputing.
- **Geometry — triangle count:** `RendererMetal` accumulates a per-frame counter
  over the MAIN opaque pass draws only (skip the shadow re-draw + OIT), reset at
  frame start. Each draw adds `indexCount/3` (indexed) or `vertexCount/3`
  (non-indexed triangles); impostors add their billboard triangles. This tracks
  cartoon_sampling directly (more sampling → more triangles), which is the point.
- **Memory:** CPU = `phys_footprint` from `task_info(TASK_VM_INFO)` (Swift). GPU =
  `MTLDevice.currentAllocatedSize` (RendererMetal holds `_device`).
- **Frame:** FPS = EMA of the wall-clock interval between rendered `draw(in:)`
  frames (Swift). Because the loop renders on-demand, show an **"idle"** state
  when no frame has rendered for ~0.5 s (so idle isn't misread as a stall).
- **Render state:** `metal_upscale` (setting value + effective on/off + render
  scale), `metal_msaa`, `metal_shadows`, `metal_raytrace`, drawable size (px),
  backing scale / Retina.

## Data flow / components

- `RendererMetal`: `_frameTriangles` (uint64, reset per frame, incremented in the
  non-shadow draw paths); getters `frameTriangleCount()` and `gpuAllocatedBytes()`
  (`_device.currentAllocatedSize`); expose the effective render scale too.
- Bridge `PyMOLBridge_GetRenderStats(uint64_t* outTriangles, uint64_t* outGpuBytes,
  float* outRenderScale)` — one call, fills the renderer-side numbers.
- `PyMOLEngine`: a `PerfHUD` observable (published fields) + `cpuFootprintBytes()`
  (mach); `applyDynamicCartoonSampling` publishes its Å/px + bucket + effective
  max + chosen sampling.
- `MetalViewport.draw(in:)`: update FPS EMA, and when `metal_perf_hud` is on,
  fetch render stats + publish to `PerfHUD`.
- `PerfHUDView` (SwiftUI): observes `PerfHUD`, renders the text block; visibility
  gated on `metal_perf_hud`.

## Files (anticipated)
- `layer1/SettingInfo.h` — `metal_perf_hud` (826).
- `layerGraphics/metal/RendererMetal.h/.mm` — triangle counter + getters.
- `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h/.mm` — `PyMOLBridge_GetRenderStats`.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `PerfHUD` object, CPU mem, LOD publish.
- `swiftui/PyMOLViewer/Shared/MetalViewport.swift` — FPS + stats fetch in draw().
- Host view file (ContentView or the viewport host) — `PerfHUDView` overlay, gated.

## Non-goals
- Not in PNG/movie exports. Not a per-pass breakdown or GPU-timestamp profiler
  (frame CPU-interval FPS is enough for tuning). No historical graphs.

## Testing
- Toggle `metal_perf_hud` on device + Mac → overlay appears/disappears.
- Zoom → LOD fields + triangle count change as `cartoon_sampling` adapts.
- FPS reads plausibly during interaction, "idle" when static.
- CPU/GPU memory are plausible and grow with a big structure/surface.
- `metal_perf_hud 0` (default) → zero overhead, byte-identical render.
