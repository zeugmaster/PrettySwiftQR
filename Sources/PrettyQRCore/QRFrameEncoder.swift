//
//  QRFrameEncoder.swift
//  PrettySwiftQR
//

import Foundation

/// Produces the sequence of QR matrices for a payload.
///
/// Static payloads yield one matrix forever. Animated payloads yield one
/// matrix per fountain part. All animated frames share one symbol version,
/// chosen up front for the longest part string the sequence can produce, so
/// the module count never changes while the code is playing.
///
/// Not thread-safe; drive it from one isolation domain (the display driver).
public final class QRFrameEncoder {
    public let payload: QRPayload
    public let errorCorrection: QRErrorCorrection
    /// Fixed symbol version used for every frame.
    public let version: Int
    /// Number of fountain source fragments (1 for static payloads).
    public let fragmentCount: Int
    public let isAnimated: Bool

    private let urEncoder: UREncoder?
    private let staticMatrix: QRMatrix?
    /// Sequence number after which the fountain encoder is rewound so the
    /// part-header encoding (and therefore frame size) never grows past `version`.
    private let wrapSequenceNumber: UInt32
    private var cache: [UInt32: QRMatrix] = [:]
    private let cacheLimit: Int

    /// The sequence number of the most recently produced frame (1-based, 0 before the first).
    public private(set) var sequenceNumber: UInt32 = 0
    /// Source fragments mixed into the most recent frame.
    public private(set) var lastFragmentIndexes: Set<Int> = []

    /// - Parameters:
    ///   - errorCorrection: nil means `.low` for animated and `.medium` for static payloads.
    public init(payload: QRPayload, errorCorrection: QRErrorCorrection? = nil, cacheLimit: Int = 64) throws {
        guard !payload.isEmpty else { throw QREncodingError.empty }
        self.payload = payload
        self.cacheLimit = cacheLimit

        switch payload {
        case .text(let text):
            let ec = errorCorrection ?? .medium
            let matrix = try QRMatrixEncoder.encode(text: text, errorCorrection: ec)
            self.errorCorrection = ec
            self.staticMatrix = matrix
            self.version = matrix.version
            self.fragmentCount = 1
            self.isAnimated = false
            self.urEncoder = nil
            self.wrapSequenceNumber = .max

        case .data(let data):
            let ec = errorCorrection ?? .medium
            let matrix = try QRMatrixEncoder.encode(data: data, errorCorrection: ec)
            self.errorCorrection = ec
            self.staticMatrix = matrix
            self.version = matrix.version
            self.fragmentCount = 1
            self.isAnimated = false
            self.urEncoder = nil
            self.wrapSequenceNumber = .max

        case .animated, .ur:
            let ur = payload.ur!
            let maxFragmentLength = max(10, payload.maxFragmentLength ?? QRPayload.defaultMaxFragmentLength)
            let encoder = UREncoder(ur, maxFragmentLen: maxFragmentLength)
            self.urEncoder = encoder
            self.fragmentCount = encoder.seqLen

            if encoder.isSinglePart {
                let ec = errorCorrection ?? .medium
                let matrix = try QRMatrixEncoder.encode(text: ur.qrString, errorCorrection: ec)
                self.errorCorrection = ec
                self.staticMatrix = matrix
                self.version = matrix.version
                self.isAnimated = false
                self.wrapSequenceNumber = .max
            } else {
                let ec = errorCorrection ?? .low
                self.errorCorrection = ec
                self.staticMatrix = nil
                self.isAnimated = true
                let wrap = Self.wrapSequenceNumber(fragmentCount: encoder.seqLen)
                self.wrapSequenceNumber = wrap
                let worstCase = Self.worstCasePartString(encoder: encoder, ur: ur, sequenceNumber: wrap)
                guard let version = QRMatrixEncoder.minimumVersion(forText: worstCase, errorCorrection: ec) else {
                    throw QREncodingError.tooLarge(bytes: ur.cbor.count)
                }
                self.version = version
            }
        }
    }

    /// The matrix for a static payload (or a single-part UR); nil when animated.
    public var staticFrame: QRMatrix? { staticMatrix }

    /// Produces the next frame. Static payloads return the same matrix every time.
    public func nextFrame() throws -> QRMatrix {
        if let staticMatrix {
            sequenceNumber = 1
            lastFragmentIndexes = [0]
            return staticMatrix
        }
        guard let urEncoder else { fatalError("animated encoder without UR encoder") }
        if urEncoder.seqNum >= wrapSequenceNumber {
            urEncoder.restart()
        }
        let part = urEncoder.nextPart()
        sequenceNumber = urEncoder.seqNum
        lastFragmentIndexes = urEncoder.lastFragmentIndexes
        if let cached = cache[sequenceNumber] { return cached }
        let matrix = try QRMatrixEncoder.encode(text: part.uppercased(), errorCorrection: errorCorrection, minVersion: version, maxVersion: version, boostErrorCorrection: false)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[sequenceNumber] = matrix
        return matrix
    }

    /// Rewinds to the first part.
    public func restart() {
        urEncoder?.restart()
        sequenceNumber = 0
        lastFragmentIndexes = []
    }

    // MARK: Fixed-version policy

    /// The sequence wraps before the CBOR encoding of `seqNum` would need
    /// another byte, but never before three full passes over the fragments.
    static func wrapSequenceNumber(fragmentCount: Int) -> UInt32 {
        let minimum = UInt32(clamping: fragmentCount * 3)
        for boundary: UInt32 in [23, 255, 65535] where boundary >= minimum {
            return boundary
        }
        return .max
    }

    /// The longest part string the sequence can produce before wrapping.
    static func worstCasePartString(encoder: UREncoder, ur: UR, sequenceNumber: UInt32) -> String {
        let fragmentLength = encoder.fragmentLen
        let part = FountainEncoder.Part(seqNum: sequenceNumber, seqLen: encoder.seqLen, messageLen: encoder.messageLen, checksum: .max, data: Data(repeating: 0xff, count: fragmentLength))
        let body = Bytewords.encode(part.cbor, style: .minimal)
        return "ur:\(ur.type)/\(sequenceNumber)-\(encoder.seqLen)/\(body)".uppercased()
    }
}
