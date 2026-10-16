import Testing
import Foundation
import SwiftUI
@testable import PrettySwiftQR

@Suite struct PerformanceTests {
    /// The reveal decomposes every module into its own subpath, so it is the
    /// most expensive path the shape ever builds. Budget: well under a frame.
    @Test func revealPathOnVersion20BuildsQuickly() throws {
        let text = String(repeating: "A", count: 1500)
        let matrix = try QRMatrixEncoder.encode(text: text, errorCorrection: .low)
        #expect(matrix.version >= 20)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        _ = QRCodeShape(matrix: matrix, reveal: 0.5).path(in: rect) // warm caches
        let clock = ContinuousClock()
        var worst = Duration.zero
        for step in 1...20 {
            let reveal = Double(step) / 21
            let elapsed = clock.measure {
                _ = QRCodeShape(matrix: matrix, reveal: reveal).path(in: rect)
            }
            worst = max(worst, elapsed)
        }
        let merged = clock.measure { _ = QRCodeShape(matrix: matrix, reveal: 1).path(in: rect) }
        print("reveal path (version \(matrix.version), \(matrix.darkModuleCount) dark modules): worst \(worst), merged cached \(merged)")
        // Debug builds and the simulator are several times slower than release on device.
        #expect(worst < .milliseconds(80))
    }

    @Test func animatedFrameEncodingIsFastEnoughForThirtyFPS() throws {
        let payload = QRPayload.animated(Data((0..<4000).map { UInt8($0 & 0xff) }), maxFragmentLength: 200)
        let encoder = try QRFrameEncoder(payload: payload, cacheLimit: 0)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for _ in 0..<30 {
            let elapsed = clock.measure { _ = try? encoder.nextFrame() }
            worst = max(worst, elapsed)
        }
        print("frame encode (version \(encoder.version)): worst \(worst)")
        // Encoding runs off the main actor; this only guards against pathological regressions.
        #expect(worst < .milliseconds(200))
    }
}
