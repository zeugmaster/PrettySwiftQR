import Testing
import Foundation
import SwiftUI
import CoreGraphics
import Vision
@testable import PrettySwiftQR

/// Decodes a rendered image with Vision. Returns every QR payload found.
/// Vision's barcode detector needs the neural engine or GPU; the simulator has neither.
let visionAvailable: Bool = {
    #if targetEnvironment(simulator)
    return false
    #else
    return true
    #endif
}()

func visionDecode(_ image: CGImage) throws -> [String] {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { $0.payloadStringValue }
}

func render(_ matrix: QRMatrix, radii: QROutlineRadii, pixelSize: Int = 600) throws -> CGImage {
    let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    return try #require(QRCodeImageRenderer.cgImage(matrix: matrix, radii: radii, quietZone: 2, pixelSize: pixelSize, foreground: black, background: white))
}

@Suite struct RenderTests {
    @Test(.enabled(if: visionAvailable), arguments: [0.0, 0.25, 0.5])
    func roundedStaticCodesStillScan(moduleRadius: Double) throws {
        for text in ["https://example.com", String(repeating: "cashuA", count: 60), String(repeating: "7", count: 400)] {
            let matrix = try QRMatrixEncoder.encode(text: text, errorCorrection: .medium)
            for inner in [0.0, moduleRadius] {
                let radii = QROutlineRadii.derived(module: moduleRadius, inner: inner)
                let image = try render(matrix, radii: radii)
                #expect(try visionDecode(image) == [text], "radius \(moduleRadius) inner \(inner) version \(matrix.version)")
            }
        }
    }

    @Test(.enabled(if: visionAvailable)) func largeSymbolScansWhenRounded() throws {
        let text = String(repeating: "A", count: 1500)
        let matrix = try QRMatrixEncoder.encode(text: text, errorCorrection: .low)
        #expect(matrix.version >= 20)
        let image = try render(matrix, radii: .round, pixelSize: 1200)
        #expect(try visionDecode(image) == [text])
    }

    @Test(.enabled(if: visionAvailable)) func animatedFramesScanAndReassemble() throws {
        let message = Data((0..<1400).map { UInt8(($0 * 31) & 0xff) })
        let encoder = try QRFrameEncoder(payload: .animated(message, maxFragmentLength: 150))
        let decoder = ScanDecoder()
        var result: ScanResult?
        for _ in 0..<(encoder.fragmentCount * 2) {
            let frame = try encoder.nextFrame()
            let decoded = try visionDecode(try render(frame, radii: .round, pixelSize: 700))
            #expect(decoded.count == 1)
            for code in decoded {
                if case .completed(let r) = decoder.receive(code) { result = r }
            }
            if result != nil { break }
        }
        #expect(result?.data == message)
    }

    @Test func renderedPNGHasExpectedSize() throws {
        let matrix = try QRMatrixEncoder.encode(text: "png", errorCorrection: .low)
        let image = try render(matrix, radii: .round, pixelSize: 256)
        #expect(image.width == 256 && image.height == 256)
        let png = try #require(QRCodeImageRenderer.pngData(image))
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4e, 0x47])
    }

    @Test func svgExportForStaticPayload() throws {
        let svg = try #require(try QRCodeImageRenderer.svg(for: .text("svg")))
        #expect(svg.hasPrefix("<svg"))
        #expect(try QRCodeImageRenderer.svg(for: .animated(Data(repeating: 1, count: 2000))) == nil)
    }
}

@Suite struct ShapeTests {
    func elementCount(_ path: Path) -> Int {
        var n = 0
        path.forEach { _ in n += 1 }
        return n
    }

    @Test func fullRevealUsesMergedOutline() throws {
        let matrix = try QRMatrixEncoder.encode(text: "shape", errorCorrection: .low)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let full = QRCodeShape(matrix: matrix, reveal: 1).path(in: rect)
        let merged = Path(qrCommands: QROutline.trace(matrix) + QROutline.finders(matrix), scale: 200 / 25, origin: CGPoint(x: 16, y: 16))
        #expect(elementCount(full) == elementCount(merged))
        #expect(full.boundingRect.minX >= 15.9 && full.boundingRect.maxX <= 184.1)
    }

    @Test func partialRevealShrinksCellsAndZeroIsEmpty() throws {
        let matrix = try QRMatrixEncoder.encode(text: "shape", errorCorrection: .low)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(QRCodeShape(matrix: matrix, reveal: 0).path(in: rect).isEmpty)
        let half = QRCodeShape(matrix: matrix, reveal: 0.5, revealStyle: QRReveal(order: .simultaneous, stagger: 0)).path(in: rect)
        let full = QRCodeShape(matrix: matrix, reveal: 1).path(in: rect)
        #expect(!half.isEmpty)
        // Every cell is its own subpath while revealing, so there are many more elements.
        #expect(elementCount(half) > elementCount(full))
        // The finder scales about its centre by the eased reveal scale.
        let style = QRReveal(order: .simultaneous, stagger: 0, overshoot: 0)
        let finder = QRCodeShape(matrix: QRMatrix(rows: Array(repeating: Array(repeating: false, count: 21), count: 21)), reveal: 0.5, revealStyle: style).path(in: rect)
        let moduleSize = 200.0 / 25
        let scale = style.scale(reveal: 0.5, delay: 0)
        #expect(scale > 0.5 && scale < 1)
        #expect(abs(finder.boundingRect.minX - (16 + (3.5 - 3.5 * scale) * moduleSize)) < 0.01)
    }

    @Test func matrixSwapDoesNotTouchAnimatableData() throws {
        var shape = QRCodeShape(matrix: try QRMatrixEncoder.encode(text: "a", errorCorrection: .low), reveal: 1)
        shape.matrix = try QRMatrixEncoder.encode(text: "b", errorCorrection: .low)
        #expect(shape.animatableData == 1)
        shape.animatableData = 2
        #expect(shape.reveal == 1)
    }

    @Test func displacingRevealRunsTheStaggerBackwards() {
        let reveal = QRReveal(order: .fromCenter, stagger: 0.5)
        let centre = QRPoint(10.5, 10.5), corner = QRPoint(0, 0)
        #expect(reveal.delay(for: centre, size: 21) < 0.05)
        #expect(abs(reveal.delay(for: corner, size: 21) - 0.5) < 1e-9)
        #expect(abs(reveal.displacing.delay(for: centre, size: 21) - 0.5) < 0.05)
        #expect(reveal.displacing.delay(for: corner, size: 21) < 1e-9)
        #expect(reveal.displacing.displacing == reveal)
        #expect(reveal.displacing != reveal)
    }

    @Test func revealTimingIsMonotonicAndBounded() {
        let reveal = QRReveal(order: .fromCenter, stagger: 0.5, overshoot: 0.1)
        let center = reveal.delay(for: QRPoint(10.5, 10.5), size: 21)
        let corner = reveal.delay(for: QRPoint(0.5, 0.5), size: 21)
        #expect(center < corner)
        #expect(corner <= 0.5)
        var previous = -1.0
        for step in 0...100 {
            let s = reveal.scale(reveal: Double(step) / 100, delay: corner)
            #expect(s >= 0 && s <= 1 + reveal.overshoot * 2)
            if step > 0 && s < 1 { #expect(s >= previous - 1e-9) }
            previous = s
        }
        #expect(reveal.scale(reveal: 1, delay: corner) == 1)
        #expect(reveal.scale(reveal: 0, delay: 0) == 0)
        #expect(QRReveal(order: .simultaneous).delay(for: QRPoint(0, 0), size: 21) == 0)
        let random = QRReveal(order: .random(seed: 7))
        #expect(random.delay(for: QRPoint(3, 4), size: 21) == random.delay(for: QRPoint(3, 4), size: 21))
    }

    @Test func pathCacheReturnsIdenticalCommands() throws {
        let matrix = try QRMatrixEncoder.encode(text: "cache", errorCorrection: .low)
        let a = QRPathCache.shared.merged(matrix: matrix, radii: .round)
        let b = QRPathCache.shared.merged(matrix: matrix, radii: .round)
        #expect(a == b)
        #expect(QRPathCache.shared.merged(matrix: matrix, radii: .square) != a)
    }

    // MARK: Fill rule

    func rasterize(_ commands: [QRPathCommand], rule: CGPathFillRule, scale: CGFloat, size: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setShouldAntialias(true)
        context.addPath(Path(qrCommands: commands, scale: scale, origin: .zero).cgPath)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillPath(using: rule)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: size * size))
    }

    /// The merged outline must look the same under both rules: that proves the
    /// contour orientation (holes reversed) is right, so `QRCodeView`'s nonzero
    /// fill draws exactly what the even-odd fill used to.
    @Test(arguments: ["a", "https://example.com/pay?amount=21", String(repeating: "cashuA", count: 60)])
    func mergedOutlineIsFillRuleIndependent(text: String) throws {
        let matrix = try QRMatrixEncoder.encode(text: text, errorCorrection: .medium)
        let custom = QROutlineRadii(module: 0.3, inner: 0.2, finderOuter: 1, finderInner: 0.5, finderCenter: 0.2)
        for radii in [QROutlineRadii.round, .square, custom] {
            let commands = QROutline.trace(matrix, radii: radii) + QROutline.finders(matrix, radii: radii)
            let size = matrix.size * 8
            let winding = try rasterize(commands, rule: .winding, scale: 8, size: size)
            let evenOdd = try rasterize(commands, rule: .evenOdd, scale: 8, size: size)
            let maxDiff = zip(winding, evenOdd).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(maxDiff <= 1)
            #expect(winding.contains(255), "finder eyes must remain holes")
        }
    }

    /// While a reveal overshoots, neighbouring cells overlap slightly. Under
    /// nonzero they union; under even-odd the overlaps would be carved out.
    @Test func overlappingRevealCellsUnionUnderNonzero() throws {
        let block = QRMatrix(rows: Array(repeating: Array(repeating: true, count: 3), count: 3))
        let commands = QROutline.cells(block, excludeFinders: false).flatMap { QROutline.cellPath($0, radius: 0.5, scale: 1.1) }
        let winding = try rasterize(commands, rule: .winding, scale: 20, size: 60)
        let evenOdd = try rasterize(commands, rule: .evenOdd, scale: 20, size: 60)
        let middleRow = { (pixels: [UInt8]) in (6..<54).map { pixels[30 * 60 + $0] } }
        #expect(middleRow(winding).allSatisfy { $0 == 0 }, "overlapping cells left a seam under nonzero")
        #expect(middleRow(evenOdd).contains { $0 > 0 }, "even-odd was expected to carve the overlaps")
    }
}
