import Testing
import Foundation
@testable import PrettyQRCore

@Suite struct QRGeometryTests {
    func corners(_ commands: [QRPathCommand]) -> (convex: Int, concave: Int) {
        var convex = 0, concave = 0
        for c in commands { if case .corner(_, _, _, let isConvex) = c { if isConvex { convex += 1 } else { concave += 1 } } }
        return (convex, concave)
    }

    func subpaths(_ commands: [QRPathCommand]) -> Int {
        commands.filter { if case .move = $0 { return true } else { return false } }.count
    }

    @Test func singleModuleIsFourConvexCorners() {
        let m = QRMatrix(rows: [[true]])
        let path = QROutline.trace(m, radii: .round, excludeFinders: false)
        #expect(path.count == 6)
        #expect(corners(path) == (4, 0))
        #expect(subpaths(path) == 1)
        guard case .move(let start) = path[0] else { Issue.record("no move"); return }
        #expect(start == QRPoint(0.5, 0))
    }

    @Test func horizontalPairHasStraightTopAndBottom() {
        let m = QRMatrix(rows: [[true, true], [false, false]])
        let path = QROutline.trace(m, excludeFinders: false)
        #expect(corners(path) == (4, 0))
        #expect(path.filter { if case .line = $0 { return true } else { return false } }.count == 2)
    }

    @Test func lShapeHasOneConcaveCorner() {
        let m = QRMatrix(rows: [[true, true], [true, false]])
        let path = QROutline.trace(m, excludeFinders: false)
        #expect(subpaths(path) == 1)
        #expect(corners(path) == (5, 1))
        #expect(QROutline.fillets(m, excludeFinders: false).count == 1)
        #expect(QROutline.fillets(m, excludeFinders: false).first == QRFillet(corner: QRPoint(1, 1), quadrantX: 1, quadrantY: 1))
    }

    @Test func ringProducesOuterAndHoleSubpaths() {
        let m = QRMatrix(rows: [
            [true, true, true],
            [true, false, true],
            [true, true, true],
        ])
        let path = QROutline.trace(m, excludeFinders: false)
        #expect(subpaths(path) == 2)
        // The hole's four corners are concave: three dark modules meet at each.
        #expect(corners(path) == (4, 4))
        #expect(QROutline.fillets(m, excludeFinders: false).count == 4)
    }

    @Test func diagonalModulesStaySeparate() {
        let m = QRMatrix(rows: [[true, false], [false, true]])
        let path = QROutline.trace(m, excludeFinders: false)
        #expect(subpaths(path) == 2)
        #expect(corners(path) == (8, 0))
    }

    @Test func cellsExposeOnlyOutlineCorners() {
        let m = QRMatrix(rows: [[true, true], [true, false]])
        let cells = QROutline.cells(m, excludeFinders: false)
        #expect(cells.count == 3)
        #expect(cells.first { $0.x == 0 && $0.y == 0 }?.roundedCorners == [.topLeft])
        #expect(cells.first { $0.x == 1 && $0.y == 0 }?.roundedCorners == [.topRight, .bottomRight])
        #expect(cells.first { $0.x == 0 && $0.y == 1 }?.roundedCorners == [.bottomLeft, .bottomRight])
        #expect(QROutline.cellPath(cells[0], radius: 0.5, scale: 0.5).count == 10)
    }

    @Test func findersAreExcludedFromTraceAndCells() throws {
        let m = try QRMatrixEncoder.encode(text: "finder test", errorCorrection: .low)
        let cells = QROutline.cells(m)
        #expect(cells.allSatisfy { !m.isFinder(x: $0.x, y: $0.y) })
        let finderCommands = QROutline.finders(m)
        #expect(subpaths(finderCommands) == 9)
        let everything = QROutline.cells(m, excludeFinders: false)
        #expect(everything.count == m.darkModuleCount)
        #expect(cells.count == m.darkModuleCount - 3 * 33) // 33 dark modules per finder
    }

    @Test func radiiClampToGeometry() {
        let r = QROutlineRadii(module: 2, inner: -1, finderOuter: 10, finderInner: 10, finderCenter: 10)
        #expect(r.module == 0.5)
        #expect(r.inner == 0)
        #expect(r.finderOuter == 3.5)
        #expect(r.finderInner == 2.5)
        #expect(r.finderCenter == 1.5)
        let d = QROutlineRadii.derived(module: 0.5)
        #expect(d.finderOuter == 1.5)
        #expect(abs(d.finderInner - 1.05) < 1e-9)
        #expect(d.finderCenter == 0.75)
    }

    @Test func tangentPointsSitOnSegments() {
        let (a, b) = QROutline.tangentPoints(from: QRPoint(0.5, 0), corner: QRPoint(1, 0), end: QRPoint(1, 0.5), radius: 0.5)
        #expect(a == QRPoint(0.5, 0))
        #expect(b == QRPoint(1, 0.5))
        let (c, d) = QROutline.tangentPoints(from: QRPoint(0.5, 0), corner: QRPoint(1, 0), end: QRPoint(1, 0.5), radius: 0.2)
        #expect(abs(c.x - 0.8) < 1e-9 && c.y == 0)
        #expect(d.x == 1 && abs(d.y - 0.2) < 1e-9)
    }

    @Test func svgIsWellFormed() throws {
        let m = try QRMatrixEncoder.encode(text: "svg", errorCorrection: .low)
        let svg = QROutline.svg(m, radii: .round, quietZone: 2)
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-2.0 -2.0 25.0 25.0\">"))
        #expect(svg.contains("fill-rule=\"nonzero\""))
        #expect(svg.contains(" A0.5 0.5 0 0 1 ") || svg.contains("A0.5 0.5 0 0 1 "))
        #expect(svg.hasSuffix("</svg>"))
        let square = QROutline.svg(m, radii: .square)
        #expect(!square.contains("A"))
    }

    // MARK: Orientation (the nonzero fill rule depends on it)

    /// Shoelace sum per subpath, with each arc approximated by its tangent
    /// points and midpoint. Positive means clockwise on screen (y down).
    func signedAreas(_ commands: [QRPathCommand]) -> [Double] {
        var areas: [Double] = []
        var points: [QRPoint] = []
        var current = QRPoint(0, 0)
        func flush() {
            if points.count >= 3 {
                var sum = 0.0
                for i in points.indices {
                    let p = points[i], q = points[(i + 1) % points.count]
                    sum += p.x * q.y - q.x * p.y
                }
                areas.append(sum / 2)
            }
            points = []
        }
        for command in commands {
            switch command {
            case .move(let p): flush(); points = [p]; current = p
            case .line(let p): points.append(p); current = p
            case .corner(let corner, let end, let radius, _):
                let (t1, t2) = QROutline.tangentPoints(from: current, corner: corner, end: end, radius: radius)
                let center = QRPoint(t1.x + t2.x - corner.x, t1.y + t2.y - corner.y)
                let mid = QRPoint(center.x + (corner.x - center.x) / 2.0.squareRoot(), center.y + (corner.y - center.y) / 2.0.squareRoot())
                points += [t1, mid, t2]
                current = end
            case .close: break
            }
        }
        flush()
        return areas
    }

    /// Every `convex` flag must agree with the direction of the turn it describes.
    func turnFlagsAreConsistent(_ commands: [QRPathCommand]) -> Bool {
        var current = QRPoint(0, 0)
        for command in commands {
            switch command {
            case .move(let p), .line(let p): current = p
            case .corner(let corner, let end, let radius, let convex):
                // A zero radius leaves nothing to orient (`end` may equal `corner`).
                if radius > 0 {
                    let cross = (corner.x - current.x) * (end.y - corner.y) - (corner.y - current.y) * (end.x - corner.x)
                    if cross == 0 || convex != (cross > 0) { return false }
                }
                current = end
            case .close: break
            }
        }
        return true
    }

    @Test func tracedOuterContoursAreClockwiseAndHolesCounterClockwise() {
        let ring = QRMatrix(rows: [[true, true, true], [true, false, true], [true, true, true]])
        let path = QROutline.trace(ring, excludeFinders: false)
        let areas = signedAreas(path)
        #expect(areas.count == 2)
        #expect(areas[0] > 0)
        #expect(areas[1] < 0)
        #expect(turnFlagsAreConsistent(path))
    }

    @Test func finderEyeRingIsCounterClockwise() {
        for radii in [QROutlineRadii.round, .square] {
            let finder = QROutline.finder(atX: 0, y: 0, radii: radii)
            let areas = signedAreas(finder)
            #expect(areas.count == 3)
            #expect(areas[0] > 0 && areas[1] < 0 && areas[2] > 0)
            #expect(turnFlagsAreConsistent(finder))
        }
    }

    @Test func cellsAndFilletsAreClockwiseInEveryQuadrant() {
        let cell = QRCell(x: 2, y: 2, roundedCorners: [.topLeft, .bottomRight])
        #expect(signedAreas(QROutline.cellPath(cell, radius: 0.5, scale: 1.1)) == signedAreas(QROutline.cellPath(cell, radius: 0.5, scale: 1.1)).filter { $0 > 0 })
        for qx in [-1, 1] {
            for qy in [-1, 1] {
                let path = QROutline.filletPath(QRFillet(corner: QRPoint(3, 3), quadrantX: qx, quadrantY: qy), radius: 0.5)
                let areas = signedAreas(path)
                #expect(areas.count == 1 && areas[0] > 0, "fillet in quadrant (\(qx), \(qy)) is not clockwise")
                #expect(turnFlagsAreConsistent(path))
            }
        }
    }

    @Test func realSymbolHasConsistentTurnFlags() throws {
        let matrix = try QRMatrixEncoder.encode(text: "orientation", errorCorrection: .medium)
        let radii = QROutlineRadii(module: 0.4, inner: 0.3, finderOuter: 2, finderInner: 1, finderCenter: 0.5)
        #expect(turnFlagsAreConsistent(QROutline.trace(matrix, radii: radii) + QROutline.finders(matrix, radii: radii)))
        #expect(signedAreas(QROutline.finders(matrix, radii: radii)).count == 9)
    }
}
