# CGOGL.cpp Renderer Refactoring Plan

## Overview

`layer1/CGOGL.cpp` (2573 lines, ~198 direct GL calls) is the CGO-to-OpenGL rendering
engine. It implements the callback table (`CGO_gl[]`) that the CGO interpreter dispatches
to, plus two top-level render functions (`CGORenderGL`, `CGORenderGLAlpha`).

## GL Call Inventory

### 1. Immediate Mode (glBegin/glEnd) — 5 paired blocks

| Location | Function | Primitive | Notes |
|----------|----------|-----------|-------|
| L76/L92 | `CGO_gl_begin` / `CGO_gl_end` | variable | CGO dispatch callbacks; begin and end are separate functions called by the CGO opcode interpreter. Vertices/colors/normals arrive via other CGO opcodes (`CGO_gl_vertex`, `CGO_gl_line`, `CGO_gl_splitline`, `CGO_gl_color`, `CGO_gl_normal`). **Cannot be replaced in isolation.** |
| L378–399 | `CGO_gl_draw_arrays` (legacy path) | variable | Self-contained loop over vertex/color/normal arrays. **Good candidate for batch replacement.** |
| L1360–1362 | `CGO_gl_special_with_arg` LINEWIDTH_FOR_LINES | GL_LINES | Temporarily ends/restarts a begin/end block from CGO dispatch to change line width. **Tied to the CGO dispatch begin/end; cannot replace alone.** |
| L2530–2549 | `CGORenderGLAlpha` (sorted path) | GL_TRIANGLES | Self-contained: iterates bins, emits color+normal+vertex per triangle. **Good candidate.** |
| L2554–2569 | `CGORenderGLAlpha` (unsorted path) | GL_TRIANGLES | Self-contained: iterates CGO ops, emits color+normal+vertex per triangle. **Good candidate.** |

### 2. State Management (~30 calls)

| Call | Count | Locations |
|------|-------|-----------|
| `glEnable` | 12 | L1269, 1370, 1388, 1395, 1397, 1408, 1415, 1558, 1561, 1567, 1578, 1614, 1629 |
| `glDisable` | 11 | L1276, 1372, 1385, 1386, 1402, 1403, 1412, 1474, 1489, 1597, 1650, 1653, 1659, 1667 |
| `glColorMask` | 2 | L780, 783 |
| `glLineWidth` | 7 | L897, 1023, 1034, 1361, 1902, 2202 (via `glLineWidthAndUniform`) |
| `glPointSize` | 3 | L1120, 1209, 1409, 1426 |
| `glHint` | 4 | L1389, 1398, 1401 (not in Renderer) |
| `glAlphaFunc` | 2 | L1396, 1413 (not in Renderer) |

### 3. Buffer Operations (~20 calls)

| Call | Count | Context |
|------|-------|---------|
| `glGenBuffers` | 1 | L240 (WebGL path in `CGO_gl_draw_arrays`) |
| `glDeleteBuffers` | 1 | L334 (WebGL path) |
| `glBindBuffer` | 6 | L258, 271, 288, 301, 925, 982 |
| `glBufferData` | 5 | L259, 272, 289, 302 |

### 4. Drawing (~20 calls)

| Call | Count | Locations |
|------|-------|-----------|
| `glDrawArrays` | 10 | L319, 596, 662, 710, 712, 729, 844, 904, 931, 955, 992 |
| `glDrawElements` | 4 | L543, 660, 781, 786 |

### 5. Vertex Attributes (~40 calls)

| Call | Count | Context |
|------|-------|---------|
| `glVertexAttribPointer` | 12 | Throughout draw_arrays, draw_buffers_indexed, etc. |
| `glEnableVertexAttribArray` | 10 | Paired with draws |
| `glDisableVertexAttribArray` | 8 | Paired with draws |
| `glVertexAttrib4ubv` | 4 | L704, 771, 772 (picking nopick color) |
| `glVertexAttrib4f` | 1 | L1701 (color via shader) |
| `glVertexAttrib3fv` | 2 | L216, 1728 |
| `glVertexAttrib1f` | 1 | L1766 |

### 6. Legacy Fixed-Function (~15 calls, all inside `#ifndef PURE_OPENGL_ES_2`)

| Call | Locations | Notes |
|------|-----------|-------|
| `glVertex3fv` | L109, 137–149, 159–205, 396, 2538–2566 | Part of begin/end blocks |
| `glColor4ub/ubv` | L187, 194, 202, 383, 1921 | Part of begin/end or picking |
| `glColor4f/fv` | L387, 1705, 2194, 2536–2564 | Part of begin/end or legacy color |
| `glNormal3f/fv` | L222, 391, 2537–2565 | Part of begin/end or legacy normal |

### 7. Misc

| Call | Location | Notes |
|------|----------|-------|
| `glGetFloatv` | L423 | Query modelview matrix |

## Renderer Methods Available

The `Renderer` interface (layerGraphics/Renderer.h) already provides:

- **State**: `enable`, `disable`, `blendFunc`, `depthFunc`, `depthMask`, `colorMask`, `lineWidth`, `pointSize`
- **Drawing**: `drawArrays`, `drawElements`
- **Buffers**: `createBuffer`, `deleteBuffer`, `bindBuffer`, `bufferData`
- **Vertex attrs**: `vertexAttribPointer`, `enableVertexAttribArray`, `disableVertexAttribArray`
- **Shaders**: `useProgram`, `setUniform*`
- **Batch (imm-mode replacement)**: `beginBatch`, `batchVertex3f/3fv`, `batchColor3f/3fv/4f`, `batchNormal3fv`, `endBatch`

## Gaps — New Renderer Methods Needed

| Method | Used by | Priority |
|--------|---------|----------|
| `batchColor4fv(const float*)` | Alpha triangle rendering (L2536–2565) | High — simple addition |
| `glHint(...)` | Sphere mode ops (L1389, 1398, 1401) | Low — legacy, can skip |
| `glAlphaFunc(...)` | Sphere mode ops (L1396, 1413) | Low — legacy, can skip |
| `glGetFloatv(...)` | Matrix query (L423) | Medium — needed for transparency sort |
| `vertexAttrib4ubv/4f/3fv/1f` | Various picking/color (L704, 1701, 1728, 1766) | Medium — these are shader attribute calls, not batch calls |

## Refactoring Order

### Phase 1: Low-Risk Batch Replacements (this PR)

1. **`CGO_gl_draw_arrays` legacy path (L378–399)**: Replace the `glBegin/glEnd` loop
   with `beginBatch`/`batchColor4f`/`batchNormal3fv`/`batchVertex3fv`/`endBatch`.
   Requires adding `batchColor4fv` to Renderer or manually decomposing.

2. **`CGORenderGLAlpha` sorted path (L2530–2549)**: Replace with batch calls.
   Requires `batchColor4fv` (or decompose `glColor4fv`).

3. **`CGORenderGLAlpha` unsorted path (L2554–2569)**: Same pattern as sorted.

### Phase 2: State Management Replacement

Replace `glEnable`/`glDisable` calls that use `Capability` enum values with
`renderer->enable()`/`renderer->disable()`. Requires threading a `Renderer*` through
the CCGORenderer or the functions. Many calls use `GL_LIGHTING`, `GL_ALPHA_TEST`,
`GL_POINT_SMOOTH` — some of these aren't in the `Capability` enum yet.

### Phase 3: Draw Call Replacement

Replace `glDrawArrays`/`glDrawElements` with `renderer->drawArrays()`/
`renderer->drawElements()`. Requires mapping GL mode constants to `PrimitiveType` enum.

### Phase 4: Buffer and Vertex Attribute Replacement

Replace `glBindBuffer`/`glBufferData`/`glVertexAttribPointer`/etc. with Renderer
methods. These are straightforward 1:1 mappings.

### Phase 5: CGO Dispatch Begin/End Refactor (hardest)

The `CGO_gl_begin`/`CGO_gl_end` callbacks and the functions they bracket
(`CGO_gl_vertex`, `CGO_gl_line`, `CGO_gl_splitline`, `CGO_gl_color`, `CGO_gl_normal`)
form a stateful immediate-mode pipeline driven by the CGO opcode interpreter. Replacing
these requires either:

- Threading a Renderer batch through the CCGORenderer state, or
- Converting CGO streams to vertex arrays at a higher level before they reach CGOGL.

This is a major architectural change and should be done last.

## Prerequisites

- A `Renderer*` must be accessible from CGO rendering functions. Options:
  - Add `Renderer*` to `CCGORenderer`
  - Add `Renderer*` to `PyMOLGlobals`
  - Pass as parameter to `CGORenderGL`/`CGORenderGLAlpha`

## Capability Enum Gaps

These GL capabilities are used in CGOGL.cpp but missing from the `Capability` enum:
- `GL_POINT_SMOOTH` — used in sphere mode ops
- No `glHint` or `glAlphaFunc` abstraction exists
