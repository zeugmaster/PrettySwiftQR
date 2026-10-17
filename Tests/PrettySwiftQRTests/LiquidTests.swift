import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
@testable import PrettySwiftQR

private let invoice = "lightning:lnbc1u1pjexample0xyz9qrsgq7q8kz0f3n5y2w6a8d4c3v6b7n8m9"

private func symbol(_ text: String = invoice) throws -> QRMatrix {
    try QRMatrixEncoder.encode(text: text, errorCorrection: .medium)
}

@Suite struct LiquidModelTests {
    @Test func dropsHoldEveryModuleOnce() throws {
        let matrix = try symbol()
        for grid in [4, 7, 12] {
            let model = QRLiquidModel(matrix: matrix, dropsPerSide: grid, target: nil)
            var dark = 0
            for y in 0..<matrix.size {
                for x in 0..<matrix.size where matrix.isDark(x: x, y: y) && !matrix.isFinder(x: x, y: y) {
                    dark += 1
                    let id = Int(model.cellDrop[y * matrix.size + x])
                    #expect(id >= 0 && id < model.drops.count - 3)
                }
            }
            #expect(model.drops.reduce(0) { $0 + $1.mass } == Double(dark + 3 * 33))
            #expect(model.drops.suffix(3).allSatisfy { $0.isFinder })
            #expect(model.drops.count <= grid * grid + 3)
        }
    }

    @Test func threadsJoinTouchingCellsOfTheirTwoDrops() throws {
        let matrix = try symbol()
        let model = QRLiquidModel(matrix: matrix, dropsPerSide: 7, target: nil)
        #expect(!model.bonds.isEmpty)
        var perDrop = [Int](repeating: 0, count: model.drops.count)
        for bond in model.bonds {
            perDrop[bond.a] += 1; perDrop[bond.b] += 1
            #expect(abs(bond.anchorA.x - bond.anchorB.x) + abs(bond.anchorA.y - bond.anchorB.y) == 1)
            func drop(at p: SIMD2<Double>) -> Int { Int(model.cellDrop[Int(p.y) * matrix.size + Int(p.x)]) }
            #expect(drop(at: bond.anchorA) == bond.a && drop(at: bond.anchorB) == bond.b)
        }
        #expect(perDrop.allSatisfy { $0 <= 2 })
    }

    @Test func landingTilesShareTheStrokeByMass() throws {
        let model = QRLiquidModel(matrix: try symbol(), dropsPerSide: 7, target: .checkmark)
        let stroke = try #require(model.stroke)
        let total = model.drops.reduce(0) { $0 + $1.mass }
        let sorted = model.tiles.enumerated().sorted { $0.element.s < $1.element.s }
        #expect(sorted.first?.element.a == -1e4 && sorted.last?.element.b == 1e4)
        for (i, tile) in model.tiles.enumerated() where tile.a > -1e4 && tile.b < 1e4 {
            #expect(abs((tile.b - tile.a) - model.drops[i].mass / total * stroke.total) < 1e-9)
        }
        #expect(abs(stroke.halfWidth - 0.078 * Double(model.size)) < 1e-9)
    }

    @Test func atProgressZeroNothingHasMoved() throws {
        let model = QRLiquidModel(matrix: try symbol(), dropsPerSide: 7, target: .checkmark)
        for motion in [QRLiquidMotion.pullApart, .flow(.checkmark)] {
            let frame = model.frame(progress: 0, motion: motion, stagger: 0.55)
            for i in 0..<frame.dropCount {
                #expect(frame.state[i * 20 + 7] == 0, "melt")
                #expect(frame.state[i * 20 + 3] == 1, "contraction")
            }
            for k in 0..<frame.bondCount {
                #expect(frame.bonds[k * 16 + 4] == 0 && frame.bonds[k * 16 + 14] == 0, "threads must not exist at rest")
            }
            // Sides are light (0), the same drop (255) or another drop, fully attached (128).
            #expect(Set(frame.attach).isSubset(of: [0, 128, 255]))
            #expect(frame.profile.allSatisfy { $0 == -2 })
        }
    }

    @Test func endStates() throws {
        let model = QRLiquidModel(matrix: try symbol(), dropsPerSide: 7, target: .checkmark)
        let gone = model.frame(progress: 1, motion: .pullApart, stagger: 0.55)
        for i in 0..<gone.dropCount { #expect(gone.state[i * 20 + 2] == 0, "every drop has sunk") }
        let check = model.frame(progress: 1, motion: .flow(.checkmark), stagger: 0.55)
        let width = Float(try #require(model.stroke).halfWidth)
        #expect(check.profile.allSatisfy { abs($0 - width) < 1e-4 }, "the stroke is complete and even")
        for i in 0..<check.dropCount { #expect(check.state[i * 20 + 2] == 0, "every drop has landed") }
    }

    @Test func everyDropMovesOnce() throws {
        let model = QRLiquidModel(matrix: try symbol(), dropsPerSide: 7, target: .checkmark)
        for i in model.drops.indices {
            var previous = (u: -1.0, m: -1.0, l: -1.0)
            for step in 0...200 {
                let s = model.state(of: i, progress: Double(step) / 200, motion: .flow(.checkmark), stagger: 0.55)
                #expect(s.u >= previous.u && s.m >= previous.m && s.l >= previous.l)
                previous = (s.u, s.m, s.l)
            }
            #expect(previous == (1, 1, 1))
        }
    }

    @Test func modelsAreSharedBetweenViews() throws {
        let matrix = try symbol()
        let a = QRLiquidModel.cached(matrix: matrix, dropsPerSide: 7, target: nil)
        #expect(a === QRLiquidModel.cached(matrix: matrix, dropsPerSide: 7, target: nil))
        #expect(a !== QRLiquidModel.cached(matrix: matrix, dropsPerSide: 8, target: nil))
    }

    @Test func styleClampsToTheTunedRanges() {
        let style = QRLiquidStyle(tension: 2, stagger: 0, dropsPerSide: 40)
        #expect(style == QRLiquidStyle(tension: 0.6, stagger: 0.1, dropsPerSide: 12))
        #expect(QRReveal.liquid.liquid == .default)
        #expect(QRReveal.grow.liquid == nil)
        #expect(QRReveal.liquid(QRLiquidStyle(tension: 0.3), duration: 2).duration == 2)
    }
}

// MARK: Rendering

private let liquidGPU = QRLiquidGPU.prepareNow()

/// Coverage (0…1) of the foreground per pixel, from a Metal render.
private func liquidCoverage(_ matrix: QRMatrix, motion: QRLiquidMotion?, progress: Double, radii: QROutlineRadii = .round, size: Int) throws -> [Double] {
    let gpu = try #require(liquidGPU)
    let renderer = QRLiquidRenderer(gpu: gpu)
    let request = QRLiquidRequest(matrix: matrix, radii: radii, quietZone: 2, liquid: .default, motion: motion,
                                  progress: progress, foreground: SIMD4(0, 0, 0, 1))
    let bytes = try #require(renderer.pixels(request, width: size, height: size))
    return stride(from: 3, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
}

/// Coverage of a CoreGraphics path filled the way the vector outline is drawn.
private func vectorCoverage(size: Int, _ draw: (CGContext) -> Void) throws -> [Double] {
    let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(gray: 1, alpha: 1)
    context.setStrokeColor(gray: 1, alpha: 1)
    draw(context)
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (0..<(size * size)).map { Double(data[$0]) / 255 }
}

private func outlineCoverage(_ matrix: QRMatrix, radii: QROutlineRadii, size: Int) throws -> [Double] {
    try vectorCoverage(size: size) { context in
        let scale = CGFloat(size) / CGFloat(matrix.size + 4)
        let commands = QROutline.trace(matrix, radii: radii) + QROutline.finders(matrix, radii: radii)
        context.addPath(Path(qrCommands: commands, scale: scale, origin: CGPoint(x: 2 * scale, y: 2 * scale)).cgPath)
        context.fillPath(using: .winding)
    }
}

private func differingPixels(_ a: [Double], _ b: [Double], over threshold: Double = 0.1) -> Int {
    zip(a, b).filter { abs($0 - $1) > threshold }.count
}

/// Writes coverage as a PNG when LIQUID_DUMP is set, for looking at frames by eye.
private func dump(_ coverage: [Double], size: Int, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["LIQUID_DUMP"] else { return }
    let bytes = coverage.map { UInt8(255 - min(max($0, 0), 1) * 255) }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: directory).appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

@Suite(.enabled(if: liquidGPU != nil, "needs Metal")) struct LiquidRenderTests {
    /// The hand-off: the first frame of every transition must be the resting outline,
    /// or switching between the Metal view and the vector shape would jump.
    @Test(arguments: [QROutlineRadii.round, .derived(module: 0.2, inner: 0.1), .square])
    func everyTransitionStartsAsTheVectorOutline(radii: QROutlineRadii) throws {
        let size = 400
        for text in ["https://example.com", invoice, String(repeating: "cashuA", count: 60)] {
            let matrix = try symbol(text)
            let outline = try outlineCoverage(matrix, radii: radii, size: size)
            for motion in [nil, QRLiquidMotion.pullApart, .flow(.checkmark)] {
                let liquid = try liquidCoverage(matrix, motion: motion, progress: 0, radii: radii, size: size)
                let differing = differingPixels(liquid, outline)
                let name = "handoff-v\(matrix.version)-r\(Int(radii.module * 100))-\(motion == nil ? "rest" : motion?.target == nil ? "pull" : "flow")"
                dump(liquid, size: size, name: name + "-liquid")
                dump(outline, size: size, name: name + "-vector")
                #expect(differing <= size * size / 1000, "\(differing) px differ, version \(matrix.version), \(String(describing: motion))")
            }
        }
    }

    @Test func pullingApartEndsWithNothing() throws {
        let coverage = try liquidCoverage(try symbol(), motion: .pullApart, progress: 1, size: 200)
        #expect(coverage.allSatisfy { $0 < 0.02 })
    }

    @Test func flowingEndsAsTheTarget() throws {
        let matrix = try symbol()
        let size = 400
        let liquid = try liquidCoverage(matrix, motion: .flow(.checkmark), progress: 1, size: size)
        let target = try vectorCoverage(size: size) { context in
            let scale = CGFloat(size) / CGFloat(matrix.size + 4)
            let points = QRMorphTarget.checkmark.points.map { CGPoint(x: (2 + $0.x * Double(matrix.size)) * scale, y: (2 + $0.y * Double(matrix.size)) * scale) }
            context.addLines(between: points)
            context.setLineWidth(QRMorphTarget.checkmark.lineWidth * Double(matrix.size) * scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        dump(liquid, size: size, name: "check-liquid")
        dump(target, size: size, name: "check-vector")
        #expect(differingPixels(liquid, target) <= size * size / 1000)
    }

    /// Steps of 0.0005 in progress move edges by a fraction of a pixel; a pixel that
    /// flips from background to foreground (or back) in one of them is a jump.
    @Test(arguments: [QRLiquidMotion.pullApart, .flow(.checkmark)])
    func noFrameJumps(motion: QRLiquidMotion) throws {
        let matrix = try symbol()
        let size = 300
        var worst = (pixels: 0, progress: 0.0)
        for step in 0..<50 {
            let p = Double(step) / 50 + 0.01
            let a = try liquidCoverage(matrix, motion: motion, progress: p, size: size)
            let b = try liquidCoverage(matrix, motion: motion, progress: p + 0.0005, size: size)
            if step % 10 == 0 { dump(a, size: size, name: "sweep-\(motion.target == nil ? "pull" : "flow")-\(step)") }
            let flips = differingPixels(a, b, over: 0.5)
            if flips > worst.pixels { worst = (flips, p) }
        }
        // Two bodies touching flip a few pixels at once; anything larger is an artifact.
        #expect(worst.pixels <= 12, "\(worst.pixels) px jumped at progress \(worst.progress)")
    }
}

/// Renders the lab's "invoice" symbol at the lab's sample points so the port can be
/// compared with Prototypes/LiquidLab frame by frame. Only runs with LIQUID_DUMP set.
@Suite(.enabled(if: liquidGPU != nil && ProcessInfo.processInfo.environment["LIQUID_DUMP"] != nil)) struct LiquidLabComparison {
    @Test func dumpFramesForTheLab() throws {
        let matrix = try symbol()
        for (name, motion) in [("pull", QRLiquidMotion.pullApart), ("flow", .flow(.checkmark))] {
            for p in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] {
                dump(try liquidCoverage(matrix, motion: motion, progress: p, size: 600), size: 600, name: "lab-\(name)-\(Int(p * 100))")
            }
        }
        dump(try liquidCoverage(matrix, motion: nil, progress: 0, size: 600), size: 600, name: "lab-rest")
    }
}

@Suite(.enabled(if: liquidGPU != nil && ProcessInfo.processInfo.environment["LIQUID_SWEEP"] != nil)) struct LiquidDenseSweep {
    @Test func denseSweep() throws {
        for text in ["https://example.com", invoice, String(repeating: "cashuA", count: 60)] {
            let matrix = try symbol(text)
            for motion in [QRLiquidMotion.pullApart, .flow(.checkmark)] {
                var worst: [(Int, Double)] = []
                for step in 0..<200 {
                    let p = Double(step) / 200
                    let a = try liquidCoverage(matrix, motion: motion, progress: p, size: 300)
                    let b = try liquidCoverage(matrix, motion: motion, progress: p + 0.0005, size: 300)
                    let flips = differingPixels(a, b, over: 0.5)
                    if flips > 4 { worst.append((flips, p)) }
                }
                print("sweep v\(matrix.version) \(motion.target == nil ? "pull" : "flow")", worst.sorted { $0.0 > $1.0 }.prefix(6))
            }
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIQUID_TIMING"] != nil)) struct LiquidTiming {
    @Test func simulationCostPerFrame() throws {
        for text in [invoice, String(repeating: "cashuA", count: 60), String(repeating: "A", count: 1500)] {
            let matrix = try symbol(text)
            for grid in [7, 12] {
                let start = ContinuousClock.now
                let model = QRLiquidModel(matrix: matrix, dropsPerSide: grid, target: .checkmark)
                let built = ContinuousClock.now - start
                for motion in [QRLiquidMotion.pullApart, .flow(.checkmark)] {
                    let t0 = ContinuousClock.now
                    for k in 0..<60 { _ = model.frame(progress: Double(k) / 59, motion: motion, stagger: 0.55) }
                    print("timing v\(matrix.version) grid \(grid) \(motion.target == nil ? "pull" : "flow"): model \(built), frame \((ContinuousClock.now - t0) / 60)")
                }
            }
        }
    }
}
