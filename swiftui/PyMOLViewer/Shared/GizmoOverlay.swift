// GizmoOverlay.swift — Move-mode manipulation gizmo (types + Canvas overlay).
//
// The gizmo is a purely VISUAL SwiftUI Canvas drawn over the viewport
// (allowsHitTesting=false). Its geometry is computed in Python
// (modules/pymol/metal_move.py) by projecting the active object's center and
// world-axis handles to screen NDC, and read back into engine.gizmo. All input
// (hit-testing + drag) is handled in MetalViewport's gesture handlers, which
// call GizmoGeometry.hitTest to decide whether a gesture grabs a handle or falls
// through to the camera.
//
// NDC convention (matches metal_pick / MetalViewport): bottom-left origin,
// +x right, +y up, in [-1, 1].

import SwiftUI

enum InteractionMode {
    case viewing
    case move
}

enum MoveTool: String {
    case translate
    case rotate
}

/// A draggable gizmo handle. Translate tool: .x/.y/.z axis arrows, .plane (XY
/// plane), .free (screen-plane center). Rotate tool: .rx/.ry/.rz axis rings,
/// .rs screen-rotation ring.
enum GizmoHandle: String, Equatable {
    case x, y, z, plane, free
    case rx, ry, rz, rs

    /// Name passed to metal_move.begin_drag.
    var pyName: String { rawValue }
}

/// Projected gizmo geometry for one frame (all points in NDC).
struct GizmoGeometry {
    var obj: String
    var tool: MoveTool
    var center: CGPoint
    var axes: [String: CGPoint]      // "x"/"y"/"z" -> arrow tip (translate)
    var plane: CGPoint?              // XY plane handle (translate)
    var rings: [String: [CGPoint]]  // "x"/"y"/"z"/"s" -> ring polyline (rotate)
    var readout: String

    init?(json: [String: Any]) {
        guard let c = json["center"] as? [Double], c.count == 2 else { return nil }
        obj = json["obj"] as? String ?? ""
        tool = MoveTool(rawValue: json["tool"] as? String ?? "translate") ?? .translate
        center = CGPoint(x: c[0], y: c[1])
        readout = json["readout"] as? String ?? ""
        var ax: [String: CGPoint] = [:]
        if let a = json["axes"] as? [String: [Double]] {
            for (k, v) in a where v.count == 2 { ax[k] = CGPoint(x: v[0], y: v[1]) }
        }
        axes = ax
        if let p = json["plane"] as? [Double], p.count == 2 {
            plane = CGPoint(x: p[0], y: p[1])
        } else { plane = nil }
        var rg: [String: [CGPoint]] = [:]
        if let r = json["rings"] as? [String: [[Double]]] {
            for (k, v) in r { rg[k] = v.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        }
        rings = rg
    }

    // Height-normalized distance between two NDC points (NDC x is compressed by
    // aspect, so scale x back up to compare in on-screen proportions).
    private func screenDist(_ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        // Work in height-normalized space.
        let pp = CGPoint(x: p.x * aspect, y: p.y), aa = CGPoint(x: a.x * aspect, y: a.y),
            bb = CGPoint(x: b.x * aspect, y: b.y)
        let dx = bb.x - aa.x, dy = bb.y - aa.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-12 { return hypot(pp.x - aa.x, pp.y - aa.y) }
        var t = ((pp.x - aa.x) * dx + (pp.y - aa.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(pp.x - (aa.x + t * dx), pp.y - (aa.y + t * dy))
    }

    /// Closest handle to an NDC point within the hit thresholds, or nil.
    func hitTest(ndc p: CGPoint, aspect: CGFloat) -> GizmoHandle? {
        let knobR: CGFloat = 0.075     // tip / plane knob grab radius (height frac)
        let lineR: CGFloat = 0.035     // along-axis line grab distance
        let centerR: CGFloat = 0.05    // free center handle
        let ringR: CGFloat = 0.045     // ring polyline grab distance
        var best: (GizmoHandle, CGFloat)?
        func consider(_ h: GizmoHandle, _ d: CGFloat, _ limit: CGFloat) {
            if d <= limit, best == nil || d < best!.1 { best = (h, d) }
        }

        if tool == .translate {
            let map: [String: GizmoHandle] = ["x": .x, "y": .y, "z": .z]
            for (k, h) in map {
                guard let tip = axes[k] else { continue }
                consider(h, screenDist(p, tip, aspect), knobR)
                consider(h, distToSegment(p, center, tip, aspect), lineR)
            }
            if let pl = plane { consider(.plane, screenDist(p, pl, aspect), knobR) }
            consider(.free, screenDist(p, center, aspect), centerR)
        } else {
            let map: [String: GizmoHandle] = ["x": .rx, "y": .ry, "z": .rz, "s": .rs]
            for (k, h) in map {
                guard let poly = rings[k], poly.count > 1 else { continue }
                var dmin = CGFloat.greatestFiniteMagnitude
                for i in 0..<(poly.count - 1) {
                    dmin = min(dmin, distToSegment(p, poly[i], poly[i + 1], aspect))
                }
                consider(h, dmin, ringR)
            }
        }
        return best?.0
    }
}

// MARK: - Visual overlay

struct GizmoOverlay: View {
    @EnvironmentObject var engine: PyMOLEngine

    private let cX = Color(red: 1.0, green: 0.36, blue: 0.36)
    private let cY = Color(red: 0.37, green: 0.84, blue: 0.41)
    private let cZ = Color(red: 0.35, green: 0.66, blue: 1.0)
    private let cAccent = Color(red: 0.25, green: 0.88, blue: 0.82)

    var body: some View {
        GeometryReader { geo in
            if let g = engine.gizmo {
                Canvas { ctx, size in
                    draw(g, in: &ctx, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // NDC (bottom-left, +y up) -> view point (top-left, +y down).
    private func pt(_ n: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: (n.x + 1) / 2 * s.width, y: (1 - n.y) / 2 * s.height)
    }

    private func color(for axis: String) -> Color {
        axis == "x" ? cX : axis == "y" ? cY : axis == "z" ? cZ : cAccent
    }

    private func draw(_ g: GizmoGeometry, in ctx: inout GraphicsContext, size s: CGSize) {
        let c = pt(g.center, s)
        if g.tool == .translate {
            for k in ["x", "y", "z"] {
                guard let tipN = g.axes[k] else { continue }
                let tip = pt(tipN, s)
                let col = color(for: k)
                var line = Path(); line.move(to: c); line.addLine(to: tip)
                ctx.stroke(line, with: .color(col), lineWidth: 3)
                drawArrowhead(&ctx, from: c, to: tip, color: col)
                let armed = engine.armedAxis?.rawValue == k
                let r: CGFloat = armed ? 9 : 6
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(col))
                if armed {
                    ctx.stroke(Path(ellipseIn: CGRect(x: tip.x - r - 4, y: tip.y - r - 4,
                                                      width: 2 * r + 8, height: 2 * r + 8)),
                               with: .color(.white), lineWidth: 1.5)
                }
            }
            if let plN = g.plane {
                let pl = pt(plN, s)
                let rect = CGRect(x: pl.x - 7, y: pl.y - 7, width: 14, height: 14)
                ctx.fill(Path(rect), with: .color(cAccent.opacity(0.25)))
                ctx.stroke(Path(rect), with: .color(cAccent), lineWidth: 1)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                     with: .color(.white))
        } else {
            for k in ["x", "y", "z", "s"] {
                guard let poly = g.rings[k], poly.count > 1 else { continue }
                var path = Path()
                path.move(to: pt(poly[0], s))
                for q in poly.dropFirst() { path.addLine(to: pt(q, s)) }
                let col = k == "s" ? Color.white.opacity(0.6) : color(for: k)
                let armedKey = k == "s" ? "rs" : "r" + k
                let armed = engine.armedAxis?.rawValue == armedKey
                ctx.stroke(path, with: .color(col), lineWidth: armed ? 4 : 2.5)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                     with: .color(.white))
        }
    }

    private func drawArrowhead(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color) {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let len: CGFloat = 9, spread: CGFloat = 0.4
        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - len * cos(ang - spread), y: b.y - len * sin(ang - spread)))
        head.addLine(to: CGPoint(x: b.x - len * cos(ang + spread), y: b.y - len * sin(ang + spread)))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }
}
