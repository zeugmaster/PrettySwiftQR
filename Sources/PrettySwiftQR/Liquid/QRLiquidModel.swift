//
//  QRLiquidModel.swift
//  PrettySwiftQR
//
//  Everything about a symbol that the liquid transitions need and that does not
//  change while they run: the drops the code is cut into, the threads between
//  neighbouring drops, where each drop lands on a morph target, and the magnets
//  that pull it apart. A port of `buildModel` in Prototypes/LiquidLab.
//

import Foundation
import os
import PrettyQRCore

final class QRLiquidModel: Sendable {
    /// A patch of modules (or a finder pattern) that moves as one body of liquid.
    struct Drop: Sendable {
        /// Centroid of its modules, in module units.
        let center: SIMD2<Double>
        let mass: Double
        /// Distance from the centroid that encloses every module.
        let extent: Double
        let isFinder: Bool
        /// Radius of the bead the patch melts into.
        let radius: Double
        /// Axis of its wobble.
        let phase: Double
        let jitter: Double
        /// Random start order for pulling apart.
        let order: Double
        /// Where it flows when pulled apart.
        let magnet: SIMD2<Double>
    }

    /// Where a drop lands on the morph target: a stretch [a, b] of arc length
    /// proportional to its mass, centred at s (point `target`).
    struct Tile: Sendable {
        let a: Double
        let b: Double
        let s: Double
        let target: SIMD2<Double>
        /// Start order: drops close to their landing spot go first.
        let key: Double
    }

    /// A thread between two neighbouring drops, anchored at the touching cells
    /// nearest the middle of the two.
    struct Bond: Sendable {
        let a: Int
        let b: Int
        let r0: Double
        let anchorA: SIMD2<Double>
        let anchorB: SIMD2<Double>
    }

    /// The morph target in module units.
    struct Stroke: Sendable {
        let points: [SIMD2<Double>]
        let lengths: [Double]
        var total: Double { lengths.last ?? 0 }
        let halfWidth: Double

        func point(at s: Double) -> SIMD2<Double> {
            let s = min(max(s, 0), total)
            for i in 1..<points.count where s <= lengths[i] || i == points.count - 1 {
                let t = (s - lengths[i - 1]) / max(1e-6, lengths[i] - lengths[i - 1])
                return points[i - 1] + (points[i] - points[i - 1]) * t
            }
            return points[0]
        }
    }

    let size: Int
    let drops: [Drop]
    let bonds: [Bond]
    /// The target, and one tile per drop; nil when the model is only used to pull apart.
    let stroke: Stroke?
    let tiles: [Tile]
    /// Drop index per module, row-major; -1 for light modules and finders.
    let cellDrop: [Int16]
    /// (n+1)² RGBA8 texels for the shader: r cell flags, g fillet code at the lattice
    /// corner (bits 0-2) and the fillets the cell owns (bits 3-6), b dark neighbours,
    /// a drop index.
    let info: [UInt8]

    init(matrix: QRMatrix, dropsPerSide: Int, target: QRMorphTarget?) {
        let n = matrix.size, grid = dropsPerSide
        func dark(_ x: Int, _ y: Int) -> Bool { matrix.isDark(x: x, y: y) && !matrix.isFinder(x: x, y: y) }

        // Modules are grouped into drops by a jittered Voronoi so the motion has no visible grid.
        var seeds: [SIMD2<Double>] = []
        for b in 0..<grid {
            for a in 0..<grid {
                let h1 = Self.sineHash(Double(a) * 127.1 + Double(b) * 311.7, 0.731)
                let h2 = Self.sineHash(Double(a) * 269.5 + Double(b) * 183.3, 0.913)
                let cell = Double(n) / Double(grid)
                seeds.append(SIMD2((Double(a) + 0.5 + (h1 - 0.5) * 0.7) * cell, (Double(b) + 0.5 + (h2 - 0.5) * 0.7) * cell))
            }
        }
        func seed(_ x: Int, _ y: Int) -> Int {
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            var best = 0, bestD = Double.infinity
            for (k, s) in seeds.enumerated() {
                let d = s - p, dd = d.x * d.x + d.y * d.y
                if dd < bestD { bestD = dd; best = k }
            }
            return best
        }

        var seedOf = [Int](repeating: -1, count: n * n)
        var members = [[SIMD2<Int>]](repeating: [], count: grid * grid)
        for y in 0..<n {
            for x in 0..<n where dark(x, y) {
                let k = seed(x, y)
                seedOf[y * n + x] = k
                members[k].append(SIMD2(x, y))
            }
        }

        var drops: [Drop] = []
        var idOfSeed = [Int](repeating: -1, count: grid * grid)
        var centers: [(center: SIMD2<Double>, mass: Double, extent: Double, finder: Bool)] = []
        for (k, cells) in members.enumerated() where !cells.isEmpty {
            idOfSeed[k] = centers.count
            let c = cells.reduce(SIMD2<Double>.zero) { $0 + SIMD2(Double($1.x) + 0.5, Double($1.y) + 0.5) } / Double(cells.count)
            let extent = cells.map { Self.length(SIMD2(Double($0.x) + 0.5, Double($0.y) + 0.5) - c) }.max()! + 0.71
            centers.append((c, Double(cells.count), extent, false))
        }
        for origin in matrix.finderOrigins {
            centers.append((SIMD2(Double(origin.x) + 3.5, Double(origin.y) + 3.5), 33, 3.5 * 2.0.squareRoot(), true))
        }

        // Magnets for pulling apart: a sparse scatter of points; every drop flows to its nearest one.
        let magnetCount = max(6, Int((Double(centers.count) / 4).rounded()))
        let magnets = (0..<magnetCount).map { k -> SIMD2<Double> in
            let x: Double = 0.08 + 0.84 * Self.hash12(Double(k) * 7.3 + 0.5, 11.1)
            let y: Double = 0.08 + 0.84 * Self.hash12(Double(k) * 3.1 + 2.9, 17.7)
            return SIMD2(x, y) * Double(n)
        }

        for (i, c) in centers.enumerated() {
            var nearest = magnets[0], nearestD = Double.infinity
            for m in magnets where Self.length(m - c.center) < nearestD {
                nearestD = Self.length(m - c.center); nearest = m
            }
            let jx: Double = Self.hash12(Double(i) * 1.3 + 4.4, 8.2) - 0.5
            let jy: Double = Self.hash12(Double(i) * 2.7 + 6.1, 9.4) - 0.5
            let jitter = SIMD2(jx, jy) * 1.2
            drops.append(Drop(
                center: c.center, mass: c.mass, extent: c.extent, isFinder: c.finder,
                radius: 0.72 * (c.mass / .pi).squareRoot(),
                phase: Self.hash12(Double(i) * 1.9 + 7.7, 5.1) * .pi,
                jitter: Self.hash12(Double(i) * 5.3 + 0.3, 9.9),
                order: Self.hash12(c.center.x.rounded(.down) + 0.37, c.center.y.rounded(.down) + 0.37),
                magnet: nearest + jitter))
        }

        var cellDrop = [Int16](repeating: -1, count: n * n)
        for i in 0..<(n * n) where seedOf[i] >= 0 { cellDrop[i] = Int16(idOfSeed[seedOf[i]]) }

        // Threads: between drops that share cell edges, at most two per drop, the longest shared
        // borders first, anchored at the touching pair nearest the middle of the two centroids.
        struct Adjacency { var count = 0; var pairs: [(SIMD2<Double>, SIMD2<Double>)] = [] }
        var adjacency: [SIMD2<Int>: Adjacency] = [:]
        var firstSeen: [SIMD2<Int>] = []
        for y in 0..<n {
            for x in 0..<n where dark(x, y) {
                let ia = Int(cellDrop[y * n + x])
                for (dx, dy) in [(1, 0), (0, 1)] where dark(x + dx, y + dy) {
                    let ib = Int(cellDrop[(y + dy) * n + x + dx])
                    guard ia != ib else { continue }
                    let key = SIMD2(min(ia, ib), max(ia, ib))
                    if adjacency[key] == nil { adjacency[key] = Adjacency(); firstSeen.append(key) }
                    let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5), q = SIMD2(Double(x + dx) + 0.5, Double(y + dy) + 0.5)
                    adjacency[key]!.count += 1
                    adjacency[key]!.pairs.append(ia < ib ? (p, q) : (q, p))
                }
            }
        }
        let ranked = firstSeen.enumerated().sorted { lhs, rhs in
            let l = adjacency[lhs.element]!.count, r = adjacency[rhs.element]!.count
            return l != r ? l > r : lhs.offset < rhs.offset
        }
        var bonds: [Bond] = []
        var perDrop = [Int](repeating: 0, count: drops.count)
        for (_, key) in ranked {
            let i = key.x, j = key.y
            guard perDrop[i] < 2, perDrop[j] < 2 else { continue }
            perDrop[i] += 1; perDrop[j] += 1
            let entry = adjacency[key]!
            let mid = (drops[i].center + drops[j].center) / 2
            var best = entry.pairs[0]
            for pair in entry.pairs.dropFirst() where Self.length((pair.0 + pair.1) / 2 - mid) < Self.length((best.0 + best.1) / 2 - mid) {
                best = pair
            }
            bonds.append(Bond(a: i, b: j, r0: 0.3 + 0.08 * Double(min(entry.count, 4)), anchorA: best.0, anchorB: best.1))
        }

        // Landing spots on the target, balanced by mass so the whole stroke fills evenly.
        var stroke: Stroke?
        var tiles: [Tile] = []
        if let target {
            let points = target.points.map { SIMD2($0.x, $0.y) * Double(n) }
            var lengths = [0.0]
            for i in 1..<points.count { lengths.append(lengths[i - 1] + Self.length(points[i] - points[i - 1])) }
            let s = Stroke(points: points, lengths: lengths, halfWidth: target.lineWidth / 2 * Double(n))
            stroke = s
            let totalMass = drops.reduce(0) { $0 + $1.mass }
            let projected = drops.enumerated().map { i, d -> (i: Int, dist: Double, su: Double) in
                var best = Double.infinity, su = 0.0
                for k in 1..<points.count {
                    let a = points[k - 1], ab = points[k] - a, len = Self.length(ab)
                    let t = Self.dot(d.center - a, ab) / max(Self.dot(ab, ab), 1e-12), tc = min(max(t, 0), 1)
                    let dist = Self.length(d.center - a - ab * tc)
                    if dist < best { best = dist; su = lengths[k - 1] + t * len }
                }
                return (i, best, su)
            }.enumerated().sorted { lhs, rhs in
                if lhs.element.su != rhs.element.su { return lhs.element.su < rhs.element.su }
                if lhs.element.dist != rhs.element.dist { return lhs.element.dist < rhs.element.dist }
                return lhs.offset < rhs.offset
            }.map(\.element)
            tiles = [Tile](repeating: Tile(a: 0, b: 0, s: 0, target: .zero, key: 0), count: drops.count)
            var cumulative = 0.0
            for (k, p) in projected.enumerated() {
                let d = drops[p.i]
                let a = cumulative / totalMass * s.total, b = (cumulative + d.mass) / totalMass * s.total
                cumulative += d.mass
                let sc = min(max((a + b) / 2, 0), s.total)
                let t = s.point(at: sc)
                tiles[p.i] = Tile(a: k == 0 ? -1e4 : a, b: k == projected.count - 1 ? 1e4 : b, s: sc, target: t,
                                  key: Self.length(t - d.center) / (0.7 * Double(n)))
            }
        }

        // Per-cell lookup for the shader.
        let w = n + 1
        var info = [UInt8](repeating: 0, count: w * w * 4)
        for y in 0..<n {
            for x in 0..<n where dark(x, y) {
                let l = dark(x - 1, y), r = dark(x + 1, y), u = dark(x, y - 1), d = dark(x, y + 1)
                var flags: UInt8 = 1
                if !l && !u { flags |= 2 }
                if !r && !u { flags |= 4 }
                if !r && !d { flags |= 8 }
                if !l && !d { flags |= 16 }
                var owns: UInt8 = 0
                if l && u && !dark(x - 1, y - 1) { owns |= 1 }
                if u && r && !dark(x + 1, y - 1) { owns |= 2 }
                if r && d && !dark(x + 1, y + 1) { owns |= 4 }
                if d && l && !dark(x - 1, y + 1) { owns |= 8 }
                let i = (y * w + x) * 4
                info[i] = flags
                info[i + 1] |= owns << 3
                info[i + 2] = (l ? 1 : 0) | (u ? 2 : 0) | (r ? 4 : 0) | (d ? 8 : 0)
                info[i + 3] = UInt8(cellDrop[y * n + x])
            }
        }
        for j in 0...n {
            for i in 0...n {
                let tl = dark(i - 1, j - 1), tr = dark(i, j - 1), bl = dark(i - 1, j), br = dark(i, j)
                guard [tl, tr, bl, br].filter({ $0 }).count == 3 else { continue }
                info[(j * w + i) * 4 + 1] |= !tl ? 1 : !tr ? 2 : !bl ? 3 : 4
            }
        }

        self.size = n
        self.drops = drops
        self.bonds = bonds
        self.stroke = stroke
        self.tiles = tiles
        self.cellDrop = cellDrop
        self.info = info
    }

    // MARK: Hashes shared with the lab, so both cut a symbol the same way

    static func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    static func hash12(_ x: Double, _ y: Double) -> Double {
        var px = fract(x * 0.1031), py = fract(y * 0.1031), pz = fract(x * 0.1031)
        let d = px * (py + 33.33) + py * (pz + 33.33) + pz * (px + 33.33)
        px += d; py += d; pz += d
        return fract((px + py) * pz)
    }

    static func sineHash(_ x: Double, _ k: Double) -> Double {
        abs(sin(x * k) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }

    static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
    static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }

    // MARK: Cache

    private struct Key: Hashable {
        let matrix: QRMatrix
        let dropsPerSide: Int
        let target: QRMorphTarget?
    }

    private static let cache = OSAllocatedUnfairLock<[Key: QRLiquidModel]>(initialState: [:])

    /// Models are cheap to build (a few milliseconds) but every frame of a transition needs one,
    /// and the outgoing and incoming symbols of a swap, or a morph and its way back, share them.
    static func cached(matrix: QRMatrix, dropsPerSide: Int, target: QRMorphTarget?) -> QRLiquidModel {
        let key = Key(matrix: matrix, dropsPerSide: dropsPerSide, target: target)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let model = QRLiquidModel(matrix: matrix, dropsPerSide: dropsPerSide, target: target)
        cache.withLock { cache in
            if cache.count >= 16 { cache.removeAll(keepingCapacity: true) }
            cache[key] = model
        }
        return model
    }
}
