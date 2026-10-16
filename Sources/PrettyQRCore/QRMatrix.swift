//
//  QRMatrix.swift
//  PrettySwiftQR
//

import Foundation

/// QR error correction level.
public enum QRErrorCorrection: String, Hashable, Sendable, CaseIterable, Codable {
    case low = "L"
    case medium = "M"
    case quartile = "Q"
    case high = "H"

    var ecc: QRCodeECC {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .quartile: return .quartile
        case .high: return .high
        }
    }

    init(_ ecc: QRCodeECC) {
        switch ecc {
        case .low: self = .low
        case .medium: self = .medium
        case .quartile: self = .quartile
        case .high: self = .high
        }
    }
}

/// An immutable grid of QR modules plus the metadata renderers need.
public struct QRMatrix: Hashable, Sendable {
    /// Width and height in modules (21...177).
    public let size: Int
    /// Symbol version (1...40).
    public let version: Int
    public let errorCorrection: QRErrorCorrection
    /// Mask pattern index (0...7).
    public let mask: Int
    /// Row-major, `size * size` entries. `true` is a dark module.
    public let modules: [Bool]

    public init(size: Int, version: Int, errorCorrection: QRErrorCorrection, mask: Int, modules: [Bool]) {
        precondition(modules.count == size * size, "module count must equal size²")
        self.size = size
        self.version = version
        self.errorCorrection = errorCorrection
        self.mask = mask
        self.modules = modules
    }

    init(_ qr: QRCode) {
        var modules = [Bool](repeating: false, count: qr.size * qr.size)
        for y in 0..<qr.size {
            for x in 0..<qr.size {
                modules[y * qr.size + x] = qr.getModule(x: x, y: y)
            }
        }
        self.init(size: qr.size, version: Int(qr.version.value), errorCorrection: QRErrorCorrection(qr.errorCorrectionLevel), mask: Int(qr.mask.value), modules: modules)
    }

    /// Builds a matrix from rows of `true`/`false`. Rows must be square.
    public init(rows: [[Bool]]) {
        let size = rows.count
        precondition(rows.allSatisfy { $0.count == size }, "rows must be square")
        self.init(size: size, version: max(1, (size - 17) / 4), errorCorrection: .low, mask: 0, modules: rows.flatMap { $0 })
    }

    /// `true` when the module at (x, y) is dark. Out of bounds is light.
    public func isDark(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return modules[y * size + x]
    }

    public subscript(x: Int, y: Int) -> Bool {
        isDark(x: x, y: y)
    }

    /// `true` when (x, y) lies inside one of the three 7×7 finder patterns.
    public func isFinder(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        let far = size - 7
        if x < 7 && y < 7 { return true }
        if x >= far && y < 7 { return true }
        if x < 7 && y >= far { return true }
        return false
    }

    /// Top-left origins of the three finder patterns in module coordinates.
    public var finderOrigins: [(x: Int, y: Int)] {
        [(0, 0), (size - 7, 0), (0, size - 7)]
    }

    public var darkModuleCount: Int {
        modules.lazy.filter { $0 }.count
    }

    /// Renders the matrix as text, one character per module. Handy in tests.
    public func asciiArt(dark: Character = "#", light: Character = ".") -> String {
        (0..<size).map { y in
            String((0..<size).map { x in isDark(x: x, y: y) ? dark : light })
        }.joined(separator: "\n")
    }
}

public enum QREncodingError: Error, Equatable, Sendable, LocalizedError {
    /// The payload does not fit any QR version at the requested error correction.
    case tooLarge(bytes: Int)
    /// The payload does not fit the fixed version chosen for an animated sequence.
    case frameOverflow(version: Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            return "Payload of \(bytes) bytes does not fit in a QR code."
        case .frameOverflow(let version):
            return "Frame does not fit QR version \(version)."
        case .empty:
            return "Payload is empty."
        }
    }
}

public enum QRMatrixEncoder {
    /// Encodes text choosing numeric/alphanumeric/byte segments automatically.
    public static func encode(text: String, errorCorrection: QRErrorCorrection = .medium, minVersion: Int = 1, maxVersion: Int = 40, boostErrorCorrection: Bool = true) throws -> QRMatrix {
        guard !text.isEmpty else { throw QREncodingError.empty }
        let segments = QRSegment.makeSegments(Array(text))
        return try encode(segments: segments, errorCorrection: errorCorrection, minVersion: minVersion, maxVersion: maxVersion, boostErrorCorrection: boostErrorCorrection, byteCount: text.utf8.count)
    }

    /// Encodes binary data in byte mode.
    public static func encode(data: Data, errorCorrection: QRErrorCorrection = .medium, minVersion: Int = 1, maxVersion: Int = 40, boostErrorCorrection: Bool = true) throws -> QRMatrix {
        guard !data.isEmpty else { throw QREncodingError.empty }
        let segments = [QRSegment.makeBytes(Array(data))]
        return try encode(segments: segments, errorCorrection: errorCorrection, minVersion: minVersion, maxVersion: maxVersion, boostErrorCorrection: boostErrorCorrection, byteCount: data.count)
    }

    static func encode(segments: [QRSegment], errorCorrection: QRErrorCorrection, minVersion: Int, maxVersion: Int, boostErrorCorrection: Bool, byteCount: Int) throws -> QRMatrix {
        let minV = QRCodeVersion(UInt8(min(max(minVersion, 1), 40)))
        let maxV = QRCodeVersion(UInt8(min(max(maxVersion, minVersion), 40)))
        do {
            let qr = try QRCode.encode(segments: segments, ecl: errorCorrection.ecc, minVersion: minV, maxVersion: maxV, mask: nil, boostECL: boostErrorCorrection)
            return QRMatrix(qr)
        } catch {
            if minVersion == maxVersion {
                throw QREncodingError.frameOverflow(version: minVersion)
            }
            throw QREncodingError.tooLarge(bytes: byteCount)
        }
    }

    /// The smallest version that fits `text` at `errorCorrection`, or nil if none does.
    public static func minimumVersion(forText text: String, errorCorrection: QRErrorCorrection) -> Int? {
        let segments = QRSegment.makeSegments(Array(text))
        for version in 1...40 {
            if let bits = QRSegment.getTotalBits(segments: segments, version: QRCodeVersion(UInt8(version))),
               bits <= QRCode.getNumDataCodewords(version: QRCodeVersion(UInt8(version)), ecl: errorCorrection.ecc) * 8 {
                return version
            }
        }
        return nil
    }
}
