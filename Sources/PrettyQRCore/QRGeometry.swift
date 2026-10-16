//
//  QRGeometry.swift
//  PrettySwiftQR
//
//  Platform-neutral geometry for styled QR rendering. Coordinates are in
//  module units with the origin at the matrix's top-left corner and y
//  pointing down. The contour tracer is a port of the algorithm in
//  mblode/beautiful-qr-code (MIT): it walks the boundary of every connected
//  dark region clockwise and replaces each turn with a quarter-circle arc.
//

import Foundation

public struct QRPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// A drawing command. A path is a flat list of these.
public enum QRPathCommand: Hashable, Sendable {
    case move(QRPoint)
    case line(QRPoint)
    /// A quarter-circle arc tangent to the segment that ends at `corner`
    /// (starting at the current point) and to the segment from `corner` to
    /// `end`. `convex` is true for a right-hand turn, which on a clockwise
    /// contour is a corner bulging away from the dark region; it also selects
    /// the SVG sweep direction.
    case corner(corner: QRPoint, end: QRPoint, radius: Double, convex: Bool)
    case close
}

/// Radii in module units, each clamped to its geometric maximum.
public struct QROutlineRadii: Hashable, Sendable {
    /// Convex module corners, 0...0.5.
    public var module: Double
    /// Concave fillets where two dark modules meet at a corner, 0...0.5.
    public var inner: Double
    /// Outer 7×7 finder square, 0...3.5.
    public var finderOuter: Double
    /// The 5×5 light ring inside a finder, 0...2.5.
    public var finderInner: Double
    /// The 3×3 finder centre, 0...1.5.
    public var finderCenter: Double

    public init(module: Double = 0.5, inner: Double = 0.5, finderOuter: Double = 1.5, finderInner: Double = 1.05, finderCenter: Double = 0.75) {
        self.module = min(max(module, 0), 0.5)
        self.inner = min(max(inner, 0), 0.5)
        self.finderOuter = min(max(finderOuter, 0), 3.5)
        self.finderInner = min(max(finderInner, 0), 2.5)
        self.finderCenter = min(max(finderCenter, 0), 1.5)
    }

    /// Finder radii derived from the module radius the way beautiful-qr-code does it.
    public static func derived(module: Double, inner: Double? = nil) -> QROutlineRadii {
        let m = min(max(module, 0), 0.5)
        let outer = max(0.25, m * 3)
        return QROutlineRadii(module: m, inner: inner ?? m, finderOuter: outer, finderInner: outer * 0.7, finderCenter: outer * 0.5)
    }

    public static let square = QROutlineRadii(module: 0, inner: 0, finderOuter: 0, finderInner: 0, finderCenter: 0)
    public static let round = QROutlineRadii()
}

/// One dark module and which of its corners are exposed (convex) in the outline.
public struct QRCell: Hashable, Sendable {
    public struct Corners: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let topLeft = Corners(rawValue: 1)
        public static let topRight = Corners(rawValue: 2)
        public static let bottomRight = Corners(rawValue: 4)
        public static let bottomLeft = Corners(rawValue: 8)
        public static let all: Corners = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }
    public let x: Int
    public let y: Int
    public let roundedCorners: Corners
    public var center: QRPoint { QRPoint(Double(x) + 0.5, Double(y) + 0.5) }
}

/// A concave fillet at a lattice corner where exactly three of the four
/// surrounding modules are dark. `quadrant` points into the light module.
public struct QRFillet: Hashable, Sendable {
    public let corner: QRPoint
    public let quadrantX: Int // -1 or +1
    public let quadrantY: Int // -1 or +1
}

public enum QROutline {
    // MARK: Merged outline

    /// Traces every dark region (finders excluded when `excludeFinders`) into
    /// closed subpaths with rounded corners. Outer contours run clockwise and
    /// holes counter-clockwise, so the nonzero and even-odd rules agree.
    public static func trace(_ matrix: QRMatrix, radii: QROutlineRadii = .round, excludeFinders: Bool = true) -> [QRPathCommand] {
        let n = matrix.size
        let dark = darkLookup(matrix, excludeFinders: excludeFinders)
        let stride = n + 1
        var drawn = [Bool](repeating: false, count: (2 * n + 1) * stride)
        var commands: [QRPathCommand] = []
        let convex = radii.module
        let concave = radii.inner

        func corner(_ c: QRPoint, _ end: QRPoint, convexTurn: Bool) -> QRPathCommand {
            .corner(corner: c, end: end, radius: convexTurn ? convex : concave, convex: convexTurn)
        }

        for x in 0..<n {
            for row in 0..<n {
                let y = 2 * row
                guard !drawn[y * stride + x], !dark(x, row - 1), dark(x, row) else { continue }
                commands.append(.move(QRPoint(Double(x) + 0.5, Double(row))))
                var cx = x, cy = y, dir = 0
                while !drawn[cy * stride + cx] {
                    drawn[cy * stride + cx] = true
                    let r = Double(cy / 2)
                    let fx = Double(cx)
                    switch (cy % 2, dir) {
                    case (0, 0): // heading right along the top edge of (cx, row)
                        if dark(cx + 1, cy / 2) {
                            if dark(cx + 1, cy / 2 - 1) {
                                commands.append(corner(QRPoint(fx + 1, r), QRPoint(fx + 1, r - 0.5), convexTurn: false))
                                cx += 1; cy -= 1; dir = 0
                            } else {
                                commands.append(.line(QRPoint(fx + 1.5, r)))
                                cx += 1
                            }
                        } else {
                            commands.append(corner(QRPoint(fx + 1, r), QRPoint(fx + 1, r + 0.5), convexTurn: true))
                            cx += 1; cy += 1; dir = 1
                        }
                    case (0, 1): // heading left along the bottom edge of (cx, row - 1)
                        if dark(cx - 1, cy / 2 - 1) {
                            if dark(cx - 1, cy / 2) {
                                commands.append(corner(QRPoint(fx, r), QRPoint(fx, r + 0.5), convexTurn: false))
                                cy += 1; dir = 1
                            } else {
                                commands.append(.line(QRPoint(fx - 0.5, r)))
                                cx -= 1
                            }
                        } else {
                            commands.append(corner(QRPoint(fx, r), QRPoint(fx, r - 0.5), convexTurn: true))
                            cy -= 1; dir = 0
                        }
                    case (1, 0): // heading up along the left edge of (cx, row)
                        let row = (cy - 1) / 2
                        let ry = Double(row)
                        if dark(cx, row - 1) {
                            if dark(cx - 1, row - 1) {
                                commands.append(corner(QRPoint(fx, ry), QRPoint(fx - 0.5, ry), convexTurn: false))
                                cx -= 1; cy -= 1; dir = 1
                            } else {
                                commands.append(.line(QRPoint(fx, ry - 0.5)))
                                cy -= 2
                            }
                        } else {
                            commands.append(corner(QRPoint(fx, ry), QRPoint(fx + 0.5, ry), convexTurn: true))
                            cy -= 1; dir = 0
                        }
                    default: // (1, 1): heading down along the right edge of (cx - 1, row)
                        let row = (cy - 1) / 2
                        let ry = Double(row)
                        if dark(cx - 1, row + 1) {
                            if dark(cx, row + 1) {
                                commands.append(corner(QRPoint(fx, ry + 1), QRPoint(fx + 0.5, ry + 1), convexTurn: false))
                                cy += 1; dir = 0
                            } else {
                                commands.append(.line(QRPoint(fx, ry + 1.5)))
                                cy += 2
                            }
                        } else {
                            commands.append(corner(QRPoint(fx, ry + 1), QRPoint(fx - 0.5, ry + 1), convexTurn: true))
                            cx -= 1; cy += 1; dir = 1
                        }
                    }
                }
                commands.append(.close)
            }
        }
        return commands
    }

    // MARK: Finder patterns

    /// The three finder patterns as nested rounded squares.
    public static func finders(_ matrix: QRMatrix, radii: QROutlineRadii = .round) -> [QRPathCommand] {
        var commands: [QRPathCommand] = []
        for origin in matrix.finderOrigins {
            commands += finder(atX: Double(origin.x), y: Double(origin.y), radii: radii)
        }
        return commands
    }

    /// The middle ring runs counter-clockwise so the eye is a hole under the
    /// nonzero rule as well as under even-odd.
    public static func finder(atX x: Double, y: Double, radii: QROutlineRadii) -> [QRPathCommand] {
        roundedRect(x: x, y: y, width: 7, height: 7, radius: radii.finderOuter)
            + roundedRect(x: x + 1, y: y + 1, width: 5, height: 5, radius: radii.finderInner, clockwise: false)
            + roundedRect(x: x + 2, y: y + 2, width: 3, height: 3, radius: radii.finderCenter)
    }

    /// Rounded rectangle, clockwise unless `clockwise` is false. Per-corner
    /// radii are clamped to half the shorter side.
    public static func roundedRect(x: Double, y: Double, width: Double, height: Double, topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double, clockwise: Bool = true) -> [QRPathCommand] {
        let maxRadius = min(width, height) / 2
        let tl = min(max(topLeft, 0), maxRadius), tr = min(max(topRight, 0), maxRadius)
        let br = min(max(bottomRight, 0), maxRadius), bl = min(max(bottomLeft, 0), maxRadius)
        let x1 = x + width, y1 = y + height
        if clockwise {
            return [
                .move(QRPoint(x + tl, y)),
                .line(QRPoint(x1 - tr, y)),
                .corner(corner: QRPoint(x1, y), end: QRPoint(x1, y + tr), radius: tr, convex: true),
                .line(QRPoint(x1, y1 - br)),
                .corner(corner: QRPoint(x1, y1), end: QRPoint(x1 - br, y1), radius: br, convex: true),
                .line(QRPoint(x + bl, y1)),
                .corner(corner: QRPoint(x, y1), end: QRPoint(x, y1 - bl), radius: bl, convex: true),
                .line(QRPoint(x, y + tl)),
                .corner(corner: QRPoint(x, y), end: QRPoint(x + tl, y), radius: tl, convex: true),
                .close,
            ]
        } else {
            // Same corners visited in reverse: every turn is now a left turn.
            return [
                .move(QRPoint(x, y + tl)),
                .line(QRPoint(x, y1 - bl)),
                .corner(corner: QRPoint(x, y1), end: QRPoint(x + bl, y1), radius: bl, convex: false),
                .line(QRPoint(x1 - br, y1)),
                .corner(corner: QRPoint(x1, y1), end: QRPoint(x1, y1 - br), radius: br, convex: false),
                .line(QRPoint(x1, y + tr)),
                .corner(corner: QRPoint(x1, y), end: QRPoint(x1 - tr, y), radius: tr, convex: false),
                .line(QRPoint(x + tl, y)),
                .corner(corner: QRPoint(x, y), end: QRPoint(x, y + tl), radius: tl, convex: false),
                .close,
            ]
        }
    }

    public static func roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double, clockwise: Bool = true) -> [QRPathCommand] {
        roundedRect(x: x, y: y, width: width, height: height, topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius, clockwise: clockwise)
    }

    // MARK: Per-module decomposition (used while a reveal transition runs)

    /// Every dark non-finder module with the corners that are exposed in the
    /// merged outline. Drawing all cells plus `fillets` reproduces `trace`.
    public static func cells(_ matrix: QRMatrix, excludeFinders: Bool = true) -> [QRCell] {
        let n = matrix.size
        let dark = darkLookup(matrix, excludeFinders: excludeFinders)
        var cells: [QRCell] = []
        cells.reserveCapacity(n * n / 2)
        for y in 0..<n {
            for x in 0..<n where dark(x, y) {
                var corners: QRCell.Corners = []
                let left = dark(x - 1, y), right = dark(x + 1, y), up = dark(x, y - 1), down = dark(x, y + 1)
                if !left && !up { corners.insert(.topLeft) }
                if !right && !up { corners.insert(.topRight) }
                if !right && !down { corners.insert(.bottomRight) }
                if !left && !down { corners.insert(.bottomLeft) }
                cells.append(QRCell(x: x, y: y, roundedCorners: corners))
            }
        }
        return cells
    }

    /// Lattice corners where exactly three surrounding modules are dark.
    public static func fillets(_ matrix: QRMatrix, excludeFinders: Bool = true) -> [QRFillet] {
        let n = matrix.size
        let dark = darkLookup(matrix, excludeFinders: excludeFinders)
        var fillets: [QRFillet] = []
        for j in 0...n {
            for i in 0...n {
                let tl = dark(i - 1, j - 1), tr = dark(i, j - 1), bl = dark(i - 1, j), br = dark(i, j)
                let count = [tl, tr, bl, br].filter { $0 }.count
                guard count == 3 else { continue }
                let corner = QRPoint(Double(i), Double(j))
                if !tl { fillets.append(QRFillet(corner: corner, quadrantX: -1, quadrantY: -1)) }
                else if !tr { fillets.append(QRFillet(corner: corner, quadrantX: 1, quadrantY: -1)) }
                else if !bl { fillets.append(QRFillet(corner: corner, quadrantX: -1, quadrantY: 1)) }
                else { fillets.append(QRFillet(corner: corner, quadrantX: 1, quadrantY: 1)) }
            }
        }
        return fillets
    }

    /// The closed path of one cell, scaled by `scale` about its centre.
    public static func cellPath(_ cell: QRCell, radius: Double, scale: Double = 1) -> [QRPathCommand] {
        let s = max(0, scale)
        let size = s
        let c = cell.center
        let x = c.x - size / 2, y = c.y - size / 2
        let r = min(max(radius, 0), 0.5) * s
        let corners = cell.roundedCorners
        return roundedRect(x: x, y: y, width: size, height: size,
                           topLeft: corners.contains(.topLeft) ? r : 0,
                           topRight: corners.contains(.topRight) ? r : 0,
                           bottomRight: corners.contains(.bottomRight) ? r : 0,
                           bottomLeft: corners.contains(.bottomLeft) ? r : 0)
    }

    /// The closed path of one fillet: the curved triangle between the lattice
    /// corner and the concave arc of radius `radius`. Always clockwise, like
    /// `cellPath` and `trace`, so overlapping pieces union under the nonzero rule.
    public static func filletPath(_ fillet: QRFillet, radius: Double) -> [QRPathCommand] {
        let r = min(max(radius, 0), 0.5)
        guard r > 0 else { return [] }
        let c = fillet.corner
        let onX = QRPoint(c.x + Double(fillet.quadrantX) * r, c.y)
        let onY = QRPoint(c.x, c.y + Double(fillet.quadrantY) * r)
        let (a, b) = fillet.quadrantX * fillet.quadrantY > 0 ? (onX, onY) : (onY, onX)
        return [.move(c), .line(a), .corner(corner: c, end: b, radius: r, convex: false), .close]
    }

    // MARK: SVG

    /// An SVG document in module units with a quiet zone of `quietZone` modules.
    public static func svg(_ matrix: QRMatrix, radii: QROutlineRadii = .round, quietZone: Double = 2, foreground: String = "#000000", background: String? = "#FFFFFF") -> String {
        let extent = Double(matrix.size) + quietZone * 2
        let body = trace(matrix, radii: radii) + finders(matrix, radii: radii)
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(-quietZone) \(-quietZone) \(extent) \(extent)\">"
        if let background {
            svg += "<rect x=\"\(-quietZone)\" y=\"\(-quietZone)\" width=\"\(extent)\" height=\"\(extent)\" fill=\"\(background)\"/>"
        }
        svg += "<path fill-rule=\"nonzero\" fill=\"\(foreground)\" d=\"\(svgPathData(body))\"/></svg>"
        return svg
    }

    public static func svgPathData(_ commands: [QRPathCommand]) -> String {
        var d = ""
        var current = QRPoint(0, 0)
        func fmt(_ v: Double) -> String {
            if v == v.rounded() { return String(Int(v)) }
            var s = String(format: "%.3f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        for command in commands {
            switch command {
            case .move(let p):
                d += "M\(fmt(p.x)) \(fmt(p.y))"
                current = p
            case .line(let p):
                d += "L\(fmt(p.x)) \(fmt(p.y))"
                current = p
            case .corner(let corner, let end, let radius, let convex):
                let (start, arcEnd) = tangentPoints(from: current, corner: corner, end: end, radius: radius)
                if radius > 0 {
                    if start != current { d += "L\(fmt(start.x)) \(fmt(start.y))" }
                    d += "A\(fmt(radius)) \(fmt(radius)) 0 0 \(convex ? 1 : 0) \(fmt(arcEnd.x)) \(fmt(arcEnd.y))"
                } else {
                    d += "L\(fmt(corner.x)) \(fmt(corner.y))"
                }
                if arcEnd != end { d += "L\(fmt(end.x)) \(fmt(end.y))" }
                current = end
            case .close:
                d += "Z"
            }
        }
        return d
    }

    /// Where a corner arc touches its two segments.
    public static func tangentPoints(from start: QRPoint, corner: QRPoint, end: QRPoint, radius: Double) -> (QRPoint, QRPoint) {
        func unit(_ from: QRPoint, _ to: QRPoint) -> (Double, Double) {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = (dx * dx + dy * dy).squareRoot()
            return len > 0 ? (dx / len, dy / len) : (0, 0)
        }
        let inDir = unit(start, corner)
        let outDir = unit(corner, end)
        let r = min(radius, distance(start, corner), distance(corner, end))
        return (QRPoint(corner.x - inDir.0 * r, corner.y - inDir.1 * r), QRPoint(corner.x + outDir.0 * r, corner.y + outDir.1 * r))
    }

    static func distance(_ a: QRPoint, _ b: QRPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    // MARK: Helpers

    static func darkLookup(_ matrix: QRMatrix, excludeFinders: Bool) -> (Int, Int) -> Bool {
        let n = matrix.size
        let modules = matrix.modules
        return { x, y in
            guard x >= 0, y >= 0, x < n, y < n else { return false }
            if excludeFinders {
                let far = n - 7
                if (x < 7 && y < 7) || (x >= far && y < 7) || (x < 7 && y >= far) { return false }
            }
            return modules[y * n + x]
        }
    }
}
