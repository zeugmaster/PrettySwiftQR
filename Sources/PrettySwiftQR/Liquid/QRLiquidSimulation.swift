//
//  QRLiquidSimulation.swift
//  PrettySwiftQR
//
//  The motion of the liquid transitions. Every drop gets one progress value
//  from the transition's progress, and everything else (melt, travel, landing,
//  stretch, wobble, the threads between drops) is derived from it, so each
//  drop moves as one continuous motion. The CPU computes a few hundred numbers
//  per frame; the shader only draws them. A port of `simulate` in
//  Prototypes/LiquidLab.
//

import Foundation

/// What a transition does with the code.
enum QRLiquidMotion: Hashable, Sendable {
    /// Pulled apart toward invisible magnets: progress 0 is the code, 1 is nothing.
    /// Appearing runs it backwards.
    case pullApart
    /// Flows into the target shape: progress 0 is the code, 1 the shape.
    case flow(QRMorphTarget)

    var target: QRMorphTarget? {
        if case .flow(let target) = self { return target }
        return nil
    }
}

/// One frame's worth of data for the shader.
struct QRLiquidFrame: Sendable {
    static let stateTexels = 5
    static let bondTexels = 4
    static let profileSamples = 512

    /// 5 RGBA texels per drop: (pos, radius, contraction), (direction, stretch, melt),
    /// (wobble, wobble axis, landed, progress), (centroid, extent, finder), and in
    /// column 4 the index of the drop that joins k-th.
    var state: [Float]
    /// 4 RGBA texels per thread: (end A, end B), (thread, stub, tip, satellite radii),
    /// (stub ends), (satellite position, join strength).
    var bonds: [Float]
    /// Half-width of the target along its length; negative where nothing has landed.
    var profile: [Float]
    /// Per cell and side (left, up, right, down): 0 light, 255 same drop, otherwise
    /// another drop's cell, 0.02 + 0.48 × attachment.
    var attach: [UInt8]
    var dropCount: Int
    var bondCount: Int
}

extension QRLiquidModel {
    private static let wobble = 0.45
    private static let jitter = 0.5
    /// A thread snaps at this share of its drops' progress.
    private static let snap = 0.32
    /// How much melt it takes two touching drops to tear apart.
    private static let tear = 0.2

    struct DropState {
        var u, m, e, l: Double
        var position, direction: SIMD2<Double>
        var stretch, radius, contraction, wobble, bumpWidth: Double
        var t0, t1: Double
    }

    func state(of index: Int, progress: Double, motion: QRLiquidMotion, stagger: Double) -> DropState {
        let d = drops[index]
        let flowing = motion.target != nil && !tiles.isEmpty
        let key = flowing ? Self.clamp(tiles[index].key + Self.jitter * (d.jitter - 0.5) * 0.4, 0, 1) : d.order
        let t0 = 0.5 * stagger * key, t1 = 1 - 0.5 * stagger * (1 - key)
        let u = Self.window(progress, t0, t1)
        let m = Self.smoothstep(0, 0.6, u)
        let tw = Self.window(u, 0.12, 0.9)
        let e = Self.smoother(tw), speed = Self.smootherSpeed(tw)
        let l = Self.smoothstep(0.7, 0.97, u)
        let target = flowing ? tiles[index].target : d.magnet
        let travel = target - d.center, len = Self.length(travel)
        let direction = len > 1e-3 ? travel / len : SIMD2(1, 0)
        let tt = max(0, u - 0.45)
        let to = Self.window(u, 0.85, 1)
        return DropState(
            u: u, m: m, e: e, l: l,
            position: d.center + travel * e,
            direction: direction,
            stretch: 1 + 0.35 * speed * min(1, len / 6),
            radius: d.radius * max(0, 1 - l).squareRoot(),
            contraction: 1 + (0.24 - 1) * m,
            wobble: Self.wobble * 0.2 * exp(-6 * tt) * sin(2 * .pi * 2.5 * tt) * (1 - l),
            bumpWidth: d.radius * (0.7 + 0.7 * Self.smoothstep(0.8, 1, u)) + d.radius * 0.35 * sin(2 * .pi * to) * exp(-2 * to) * (1 - to),
            t0: t0, t1: t1)
    }

    /// Where a cell of a drop is now: contracted toward the centre, moved, stretched, wobbled.
    private func cellNow(_ index: Int, _ s: DropState, _ cell: SIMD2<Double>) -> SIMD2<Double> {
        let d = drops[index]
        var p = (cell - d.center) * s.contraction
        let along = Self.dot(p, s.direction), across = p - s.direction * along
        p = s.direction * along * s.stretch + across / s.stretch.squareRoot()
        let axis = SIMD2(cos(d.phase), sin(d.phase))
        let a2 = Self.dot(p, axis), rest = p - axis * a2
        p = axis * a2 * (1 + s.wobble) + rest * (1 - s.wobble)
        return s.position + p
    }

    func frame(progress: Double, motion: QRLiquidMotion, stagger: Double) -> QRLiquidFrame {
        let count = drops.count
        let states = (0..<count).map { state(of: $0, progress: progress, motion: motion, stagger: stagger) }

        var stateData = [Float](repeating: 0, count: count * QRLiquidFrame.stateTexels * 4)
        for (i, s) in states.enumerated() {
            let d = drops[i], o = i * 20
            let values: [Double] = [
                s.position.x, s.position.y, s.radius, s.contraction,
                s.direction.x, s.direction.y, s.stretch, s.m,
                s.wobble, d.phase, s.l, s.u,
                d.center.x, d.center.y, d.extent, d.isFinder ? 1 : 0,
            ]
            for (k, v) in values.enumerated() { stateData[o + k] = Float(v) }
        }
        // The order the drops join in: latest start first. It never changes during a run.
        let order = (0..<count).sorted { (a: Int, b: Int) -> Bool in
            let ta = states[a].t0, tb = states[b].t0
            return ta != tb ? ta > tb : a < b
        }
        for (k, i) in order.enumerated() { stateData[k * 20 + 16] = Float(i) }

        var bondData = [Float](repeating: 0, count: max(1, bonds.count) * QRLiquidFrame.bondTexels * 4)
        for (k, b) in bonds.enumerated() {
            let sa = states[b.a], sb = states[b.b], o = k * 16
            let ub = max(sa.u, sb.u)
            let pa = cellNow(b.a, sa, b.anchorA), pb = cellNow(b.b, sb, b.anchorB)
            func put(_ index: Int, _ v: Double) { bondData[o + index] = Float(v) }
            put(0, pa.x); put(1, pa.y); put(2, pb.x); put(3, pb.y)
            let satellite0 = 0.32 + 0.25 * b.r0
            let tb = Self.window(ub, 0.1, Self.snap)
            let lengthFactor = min(1, 1.5 / max(1, Self.length(pb - pa))).squareRoot()
            if tb < 1 {
                // The thread grows in from nothing as the two drops begin to pull apart (at rest it
                // must not exist, or its join would inflate the outline), thins as it lengthens and
                // beads up in the middle; that bead becomes the satellite at the snap.
                let born = Self.smoothstep(0, 0.4, tb)
                put(4, b.r0 * lengthFactor * (0.3 + 0.7 * pow(1 - tb, 0.6)) * born)
                put(7, satellite0 * Self.smoothstep(0.55, 1, tb))
                let mid = (pa + pb) / 2
                put(12, mid.x); put(13, mid.y)
                put(14, born)
                continue
            }
            // Snapped, at the anchors' midpoint at the moment the thread reached its limit.
            let breakTime = min(sa.t0 + Self.snap * (sa.t1 - sa.t0), sb.t0 + Self.snap * (sb.t1 - sb.t0))
            let pab = cellNow(b.a, state(of: b.a, progress: breakTime, motion: motion, stagger: stagger), b.anchorA)
            let pbb = cellNow(b.b, state(of: b.b, progress: breakTime, motion: motion, stagger: stagger), b.anchorB)
            let mid = (pab + pbb) / 2
            let snapRadius = 0.3 * b.r0 * min(1, 1.5 / max(1, Self.length(pbb - pab))).squareRoot()
            // The stubs recoil into their drops; the retracted liquid collects in a blob at the tip.
            let tr = Self.window(ub, Self.snap, Self.snap + 0.07)
            put(5, snapRadius * pow(1 - tr, 0.6))
            put(6, snapRadius * (1 + 1.4 * tr) * pow(1 - tr, 0.5))
            let ea = pa + (mid - pab) * (1 - tr), eb = pb + (mid - pbb) * (1 - tr)
            put(8, ea.x); put(9, ea.y); put(10, eb.x); put(11, eb.y)
            // The satellite left at the break is swallowed back by the heavier drop, wherever it is now.
            let parent = drops[b.a].mass >= drops[b.b].mass ? sa : sb
            let ts = Self.window(ub, Self.snap + 0.08, 0.92), es = Self.smoother(ts)
            put(7, satellite0 * max(0, 1 - Self.smoothstep(0.8, 1, ts)).squareRoot())
            let satellite = mid + (parent.position - mid) * es
            put(12, satellite.x); put(13, satellite.y)
            put(14, 1)
        }

        // Every cell side: light, the same drop, or another drop's cell it is tearing away from.
        // The tear follows whichever of the two drops has melted further.
        let n = size
        var attach = [UInt8](repeating: 0, count: n * n * 4)
        let sides = [(-1, 0), (0, -1), (1, 0), (0, 1)]
        for y in 0..<n {
            for x in 0..<n {
                let id = Int(cellDrop[y * n + x])
                guard id >= 0 else { continue }
                for (side, (dx, dy)) in sides.enumerated() {
                    let nx = x + dx, ny = y + dy
                    let j = nx < 0 || ny < 0 || nx >= n || ny >= n ? -1 : Int(cellDrop[ny * n + nx])
                    var v: UInt8 = 0
                    if j == id {
                        v = 255
                    } else if j >= 0 {
                        let attachment = 1 - Self.smoothstep(0, Self.tear, max(states[id].m, states[j].m))
                        v = UInt8(((0.02 + 0.48 * attachment) * 255).rounded())
                    }
                    attach[(y * n + x) * 4 + side] = v
                }
            }
        }

        // The target's half-width along its length: built from the mass that has landed,
        // normalised by what the same bumps sum to once everything has landed, so the final
        // width is exact. Below the threshold the stroke sinks out of reach instead of switching off.
        var profile = [Float](repeating: -2, count: QRLiquidFrame.profileSamples)
        if let stroke, !tiles.isEmpty, motion.target != nil {
            let total = stroke.total, wf = stroke.halfWidth, eps = 0.03, ripple = 3.6 * wf * 0.5
            let last = Double(QRLiquidFrame.profileSamples - 1)
            for k in 0..<QRLiquidFrame.profileSamples {
                let s = Double(k) / last * total
                var landed = 0.0, all = 0.0, rip = 0.0
                for i in 0..<count {
                    let tile = tiles[i], st = states[i], h = max(st.bumpWidth, 0.2)
                    let bump = Self.phi((s - tile.a) / h) - Self.phi((s - tile.b) / h)
                    all += bump
                    landed += st.l * bump
                    if st.u > 0.85 && st.u < 1 {
                        // A landing sends a capillary wave along the bead that dies out as it settles.
                        let tt = Self.window(st.u, 0.85, 1), ds = abs(s - tile.s)
                        rip += 0.07 * exp(-ds / (1.5 * ripple)) * cos(2 * .pi * ds / ripple - 2 * .pi * 1.5 * tt) * exp(-2 * tt) * (1 - tt) * sin(.pi * min(1, tt * 3))
                    }
                }
                let ratio = all > 1e-6 ? landed / all : 0
                profile[k] = Float(ratio >= eps ? wf * ((ratio - eps) / (1 - eps)).squareRoot() * (1 + rip) : -2 * (1 - ratio / eps))
            }
        }

        return QRLiquidFrame(state: stateData, bonds: bondData, profile: profile, attach: attach, dropCount: count, bondCount: bonds.count)
    }

    // MARK: Easing

    static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
    static func window(_ p: Double, _ a: Double, _ b: Double) -> Double { clamp((p - a) / max(1e-3, b - a), 0, 1) }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }
    static func smoother(_ u: Double) -> Double {
        let u = clamp(u, 0, 1)
        return u * u * u * (u * (u * 6 - 15) + 10)
    }
    static func smootherSpeed(_ u: Double) -> Double {
        let u = clamp(u, 0, 1)
        return 16 * u * u * (1 - u) * (1 - u)
    }
    static func phi(_ x: Double) -> Double { 0.5 + 0.5 * tanh(1.2 * x) }
}
