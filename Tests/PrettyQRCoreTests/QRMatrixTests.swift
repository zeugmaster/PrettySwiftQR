import Testing
import Foundation
@testable import PrettyQRCore

@Suite struct QRMatrixTests {
    @Test func encodesTextAndExposesModules() throws {
        let m = try QRMatrixEncoder.encode(text: "Hello, world!", errorCorrection: .medium)
        #expect(m.version == 1)
        #expect(m.size == 21)
        #expect(m.modules.count == 21 * 21)
        // Finder pattern: dark border, light ring, dark centre.
        #expect(m.isDark(x: 0, y: 0))
        #expect(!m.isDark(x: 1, y: 1))
        #expect(m.isDark(x: 3, y: 3))
        #expect(m.isFinder(x: 6, y: 6))
        #expect(!m.isFinder(x: 7, y: 7))
        #expect(m.isFinder(x: 20, y: 0))
        #expect(m.isFinder(x: 0, y: 20))
        #expect(!m.isFinder(x: 20, y: 20))
        #expect(!m.isDark(x: -1, y: 0))
        #expect(!m.isDark(x: 21, y: 0))
    }

    @Test func upperCasedURUsesAlphanumericMode() throws {
        let ur = UR(bytes: Data(repeating: 0xab, count: 300))
        let text = ur.qrString
        let alnum = try QRMatrixEncoder.encode(text: text, errorCorrection: .low)
        let bytes = try QRMatrixEncoder.encode(data: Data(text.utf8), errorCorrection: .low)
        #expect(alnum.version < bytes.version, "alphanumeric mode must yield a smaller symbol than byte mode")
        #expect(QRSegment.isAlphanumeric(Array(text)))
    }

    @Test func overflowThrows() {
        #expect(throws: QREncodingError.tooLarge(bytes: 3000)) {
            try QRMatrixEncoder.encode(data: Data(repeating: 1, count: 3000), errorCorrection: .low)
        }
        #expect(throws: QREncodingError.frameOverflow(version: 1)) {
            try QRMatrixEncoder.encode(text: String(repeating: "A", count: 200), errorCorrection: .low, minVersion: 1, maxVersion: 1)
        }
        #expect(throws: QREncodingError.empty) { try QRMatrixEncoder.encode(text: "") }
    }

    @Test func minimumVersionAgreesWithEncoder() throws {
        for length in [10, 100, 500, 1000] {
            let text = String(repeating: "A", count: length)
            let predicted = QRMatrixEncoder.minimumVersion(forText: text, errorCorrection: .low)
            let actual = try QRMatrixEncoder.encode(text: text, errorCorrection: .low, boostErrorCorrection: false)
            #expect(predicted == actual.version)
        }
        #expect(QRMatrixEncoder.minimumVersion(forText: String(repeating: "A", count: 5000), errorCorrection: .low) == nil)
    }

    @Test func rowsInitializer() {
        let m = QRMatrix(rows: [[true, false], [false, true]])
        #expect(m.size == 2)
        #expect(m.isDark(x: 0, y: 0))
        #expect(!m.isDark(x: 1, y: 0))
        #expect(m.isDark(x: 1, y: 1))
        #expect(m.darkModuleCount == 2)
        #expect(m.asciiArt() == "#.\n.#")
    }
}
