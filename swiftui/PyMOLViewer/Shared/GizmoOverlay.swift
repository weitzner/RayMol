// GizmoOverlay.swift — Unified molecular-frame Move gizmo (types + hit-testing).
//
// One gizmo per active object, anchored on a per-object orthonormal frame
// (center of mass + N/C termini; PCA fallback). The gizmo is RENDERED as a 3D
// CGO object in the Metal scene by metal_move.py (lit tubes that wrap the
// molecule with real depth); this file only holds the shared types and the 2D
// hit-testing (GizmoGeometry.hitTest) that MetalViewport uses to route drags.
//
// NDC convention (matches metal_pick / MetalViewport): bottom-left origin,
// +x right, +y up, in [-1, 1].

import Foundation
import CoreGraphics

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

        // The white center ball OWNS its core disc: any click/hover within centerR
        // of the center is a free screen-plane drag, with ABSOLUTE priority. This
        // is essential because all three axis lines pass THROUGH the center, so
        // their distToSegment ≈ 0 for any off-by-a-pixel near-center click and
        // would otherwise steal the grab — the reason the ball was unclickable
        // except dead-center (a real click is never pixel-perfect). Axes/rings
        // stay grabbable everywhere outside this disc, out to their tips.
        if screenDist(p, center, aspect) <= centerR {
            return .free
        }

        var best: (GizmoHandle, CGFloat)?
        func consider(_ h: GizmoHandle, _ d: CGFloat, _ limit: CGFloat) {
            if d <= limit, best == nil || d < best!.1 { best = (h, d) }
        }

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

