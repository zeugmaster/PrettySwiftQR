//
//  URDecoder.swift
//
//  Copyright © 2020 by Blockchain Commons, LLC
//  Licensed under the "BSD-2-Clause Plus Patent License"
//
//  Vendored into PrettySwiftQR.
//

import Foundation

public enum URDecodingError: LocalizedError, Sendable {
    case invalidScheme
    case invalidType
    case invalidPathLength
    case invalidSequenceComponent
    case invalidFragment

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Invalid UR scheme."
        case .invalidType:
            return "Invalid UR type."
        case .invalidPathLength:
            return "Invalid UR path length."
        case .invalidSequenceComponent:
            return "Invalid UR sequence component."
        case .invalidFragment:
            return "Invalid UR fragment."
        }
    }
}

public final class URDecoder {
    /// Decode a single-part UR.
    public static func decode(_ string: String) throws -> UR {
        let (type, components) = try parse(string)
        guard let body = components.first else {
            throw URDecodingError.invalidPathLength
        }
        return try decode(type: type, body: body)
    }

    static func decode(type: String, body: String) throws -> UR {
        let cbor = try Bytewords.decode(body, style: .minimal)
        return try UR(type: type, cbor: cbor)
    }

    /// `true` when `string` looks like a UR (case-insensitive `ur:` scheme).
    public static func isURString(_ string: String) -> Bool {
        string.lowercased().hasPrefix("ur:")
    }

    /// Parses the sequence component of a multi-part UR, if present.
    /// Returns nil for single-part URs or non-UR strings.
    public static func sequenceInfo(of string: String) -> (seqNum: Int, seqLen: Int)? {
        guard let (_, components) = try? parse(string), components.count == 2 else { return nil }
        return try? parseSequenceComponent(components[0])
    }

    let fountainDecoder: FountainDecoder

    public private(set) var expectedType: String?
    public var expectedFragmentCount: Int? { fountainDecoder.expectedFragmentCount }
    public var receivedFragmentIndexes: FragmentIndexes { fountainDecoder.receivedFragmentIndexes }
    public var lastFragmentIndexes: FragmentIndexes { fountainDecoder.lastFragmentIndexes ?? [] }
    public var processedPartsCount: Int { fountainDecoder.processedPartsCount }
    public var pendingMixedPartsCount: Int { fountainDecoder.pendingMixedPartsCount }
    /// Legacy heuristic kept for parity with URKit. Prefer `fractionComplete`.
    public var estimatedPercentComplete: Double { fountainDecoder.estimatedPercentComplete }
    /// Exact fraction of source fragments recovered; 1.0 only when complete.
    public var fractionComplete: Double { fountainDecoder.fractionComplete }
    public private(set) var result: Result<UR, Swift.Error>?

    /// Start decoding a (possibly) multi-part UR.
    public init() {
        fountainDecoder = FountainDecoder()
    }

    /// Outcome of feeding one string to `receivePart`.
    public enum Outcome: Equatable, Sendable {
        /// Not a UR, or a UR that does not belong to the sequence being decoded.
        case rejected
        /// Accepted; decoding is still in progress.
        case accepted
        /// Accepted and the decoder is now complete (see `result`).
        case completed
    }

    @discardableResult
    public func receivePart(_ string: String) -> Bool {
        receive(string) != .rejected
    }

    public func receive(_ string: String) -> Outcome {
        do {
            // Don't process the part if we're already done
            guard result == nil else { return .rejected }

            // Don't continue if this part doesn't validate
            let (type, components) = try Self.parse(string)
            guard validatePart(type: type) else { return .rejected }

            // If this is a single-part UR then we're done
            if components.count == 1 {
                let body = components[0]
                result = try .success(Self.decode(type: type, body: body))
                return .completed
            }

            // Multi-part URs must have two path components: seq/fragment
            guard components.count == 2 else { throw URDecodingError.invalidPathLength }
            let seq = components[0]
            let fragment = components[1]

            // Parse the sequence component and the fragment, and
            // make sure they agree.
            let (seqNum, seqLen) = try Self.parseSequenceComponent(seq)
            let cbor = try Bytewords.decode(fragment, style: .minimal)
            let part = try FountainEncoder.Part(cbor: cbor)
            guard seqNum == part.seqNum, seqLen == part.seqLen else {
                return .rejected
            }

            // Process the part
            guard fountainDecoder.receivePart(part) else {
                return .rejected
            }

            switch fountainDecoder.result {
            case .success(let cbor)?:
                do {
                    result = try .success(UR(type: type, cbor: cbor))
                } catch {
                    result = .failure(URError.invalidCBOR)
                }
                return .completed
            case .failure(let error)?:
                result = .failure(error)
                return .completed
            case nil:
                return .accepted
            }
        } catch {
            return .rejected
        }
    }

    func validatePart(type: String) -> Bool {
        if expectedType == nil {
            guard type.isURType else { return false }
            expectedType = type
            return true
        } else {
            return type == expectedType
        }
    }

    static func parse(_ string: String) throws -> (type: String, components: [String]) {
        // Don't consider case
        let lowered = string.lowercased()

        // Validate URI scheme
        guard lowered.hasPrefix("ur:") else { throw URDecodingError.invalidScheme }
        let path = lowered.dropFirst(3)

        // Split the remainder into path components
        let components = path.split(separator: "/").map { String($0) }

        // Make sure there are at least two path components
        guard components.count > 1 else {
            throw URDecodingError.invalidPathLength
        }

        // Validate the type
        let type = components[0]
        guard type.isURType else { throw URDecodingError.invalidType }

        return (type, Array(components[1...]))
    }

    static func parseSequenceComponent(_ s: String) throws -> (seqNum: Int, seqLen: Int) {
        let scanner = Scanner(string: s)
        guard let seqNum = scanner.scanInt() else { throw URDecodingError.invalidSequenceComponent }
        guard scanner.scanString("-") != nil else { throw URDecodingError.invalidSequenceComponent }
        guard let seqLen = scanner.scanInt() else { throw URDecodingError.invalidSequenceComponent }
        guard scanner.isAtEnd else { throw URDecodingError.invalidSequenceComponent }
        guard seqNum >= 1, seqLen >= 1 else { throw URDecodingError.invalidSequenceComponent }
        return (seqNum, seqLen)
    }
}
