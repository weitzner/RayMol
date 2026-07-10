// GizmoOverlay.swift — Unified molecular-frame Move gizmo (types + Canvas overlay).
//
// One gizmo per active object, anchored on a per-object orthonormal frame
// (center of mass + N/C termini; PCA fallback) computed in metal_move.py and
// displayed through the object's current transform, so it tumbles with the
// molecule. The SAME frame drives translation (axis arrows) and rotation (rings)
// — no mode switch. This view is purely VISUAL (allowsHitTesting=false); all
// input is handled in MetalViewport, which calls GizmoGeometry.hitTest.
//
// NDC convention (matches metal_pick / MetalViewport): bottom-left origin,
// +x right, +y up, in [-1, 1].

import SwiftUI

enum InteractionMode {
    case viewing
    case move
}

/// A draggable gizmo handle: .x/.y/.z axis arrows (translate along a frame axis),
/// .rx/.ry/.rz rings (rotate about a frame axis), .free center (screen-plane drag).
enum GizmoHandle: String, Equatable {
    case x, y, z, free
    case rx, ry, rz

    var pyName: String { rawValue }
}

/// Projected gizmo geometry for one frame (all points in NDC).
struct GizmoGeometry {
    var obj: String
    var center: CGPoint
    var axes: [String: CGPoint]      // "x"/"y"/"z" -> arrow tip
    var rings: [String: [CGPoint]]  // "x"/"y"/"z" -> ring polyline
    var readout: String

    init?(json: [String: Any]) {
        guard let c = json["center"] as? [Double], c.count == 2 else { return nil }
        obj = json["obj"] as? String ?? ""
        center = CGPoint(x: c[0], y: c[1])
        readout = json["readout"] as? String ?? ""
        var ax: [String: CGPoint] = [:]
        if let a = json["axes"] as? [String: [Double]] {
            for (k, v) in a where v.count == 2 { ax[k] = CGPoint(x: v[0], y: v[1]) }
        }
        axes = ax
        var rg: [String: [CGPoint]] = [:]
        if let r = json["rings"] as? [String: [[Double]]] {
            for (k, v) in r { rg[k] = v.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        }
        rings = rg
    }

    // Height-normalized distance (NDC x is compressed by aspect).
    private func screenDist(_ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        let pp = CGPoint(x: p.x * aspect, y: p.y), aa = CGPoint(x: a.x * aspect, y: a.y),
            bb = CGPoint(x: b.x * aspect, y: b.y)
        let dx = bb.x - aa.x, dy = bb.y - aa.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-12 { return hypot(pp.x - aa.x, pp.y - aa.y) }
        var t = ((pp.x - aa.x) * dx + (pp.y - aa.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(pp.x - (aa.x + t * dx), pp.y - (aa.y + t * dy))
    }

    /// Closest handle to an NDC point within hit thresholds, or nil. Arrows,
    /// rings and the center are all live at once (nearest wins).
    func hitTest(ndc p: CGPoint, aspect: CGFloat) -> GizmoHandle? {
        let knobR: CGFloat = 0.07      // arrow tip grab radius (height frac)
        let lineR: CGFloat = 0.03      // along-axis line grab distance
        let centerR: CGFloat = 0.045   // free center handle
        let ringR: CGFloat = 0.04      // ring polyline grab distance
        var best: (GizmoHandle, CGFloat)?
        func consider(_ h: GizmoHandle, _ d: CGFloat, _ limit: CGFloat) {
            if d <= limit, best == nil || d < best!.1 { best = (h, d) }
        }

        // Center first so it wins the very middle.
        consider(.free, screenDist(p, center, aspect), centerR)

        let axisMap: [String: GizmoHandle] = ["x": .x, "y": .y, "z": .z]
        for (k, h) in axisMap {
            guard let tip = axes[k] else { continue }
            consider(h, screenDist(p, tip, aspect), knobR)
            consider(h, distToSegment(p, center, tip, aspect), lineR)
        }
        let ringMap: [String: GizmoHandle] = ["x": .rx, "y": .ry, "z": .rz]
        for (k, h) in ringMap {
            guard let poly = rings[k], poly.count > 1 else { continue }
            var dmin = CGFloat.greatestFiniteMagnitude
            for i in 0..<(poly.count - 1) {
                dmin = min(dmin, distToSegment(p, poly[i], poly[i + 1], aspect))
            }
            consider(h, dmin, ringR)
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

    var body: some View {
        GeometryReader { _ in
            if let g = engine.gizmo {
                Canvas { ctx, size in draw(g, in: &ctx, size: size) }
            }
        }
        .allowsHitTesting(false)
    }

    // NDC (bottom-left, +y up) -> view point (top-left, +y down).
    private func pt(_ n: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: (n.x + 1) / 2 * s.width, y: (1 - n.y) / 2 * s.height)
    }

    private func color(for axis: String) -> Color {
        axis == "x" ? cX : axis == "y" ? cY : cZ
    }

    // A handle is highlighted when hovered (macOS) or armed (iOS tap-to-arm).
    private func active(_ h: GizmoHandle) -> Bool {
        engine.hoveredHandle == h || engine.armedAxis == h
    }

    private func draw(_ g: GizmoGeometry, in ctx: inout GraphicsContext, size s: CGSize) {
        let c = pt(g.center, s)

        // Rotation rings (drawn first so the arrows sit on top).
        for k in ["x", "y", "z"] {
            guard let poly = g.rings[k], poly.count > 1 else { continue }
            var path = Path()
            path.move(to: pt(poly[0], s))
            for q in poly.dropFirst() { path.addLine(to: pt(q, s)) }
            let col = color(for: k)
            let on = active(GizmoHandle(rawValue: "r" + k)!)
            if on {
                ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 6)
            }
            ctx.stroke(path, with: .color(col), lineWidth: on ? 3.5 : 2)
        }

        // Translate axis arrows (thin), knobs, highlight on hover.
        for k in ["x", "y", "z"] {
            guard let tipN = g.axes[k] else { continue }
            let tip = pt(tipN, s)
            let col = color(for: k)
            let on = active(GizmoHandle(rawValue: k)!)
            var line = Path(); line.move(to: c); line.addLine(to: tip)
            if on {
                ctx.stroke(line, with: .color(.white.opacity(0.5)), lineWidth: 5)
            }
            ctx.stroke(line, with: .color(col), lineWidth: on ? 3 : 2)
            drawArrowhead(&ctx, from: c, to: tip, color: col, big: on)
            let r: CGFloat = on ? 8 : 5
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(col))
            if on {
                ctx.stroke(Path(ellipseIn: CGRect(x: tip.x - r - 3, y: tip.y - r - 3,
                                                  width: 2 * r + 6, height: 2 * r + 6)),
                           with: .color(.white), lineWidth: 1.5)
            }
        }

        // Free center handle.
        let onC = active(.free)
        let rc: CGFloat = onC ? 8 : 5
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rc, y: c.y - rc, width: 2 * rc, height: 2 * rc)),
                 with: .color(.white))
        if onC {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rc - 3, y: c.y - rc - 3,
                                              width: 2 * rc + 6, height: 2 * rc + 6)),
                       with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        }
    }

    private func drawArrowhead(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                               color: Color, big: Bool) {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let len: CGFloat = big ? 11 : 8, spread: CGFloat = 0.4
        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - len * cos(ang - spread), y: b.y - len * sin(ang - spread)))
        head.addLine(to: CGPoint(x: b.x - len * cos(ang + spread), y: b.y - len * sin(ang + spread)))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }
}
