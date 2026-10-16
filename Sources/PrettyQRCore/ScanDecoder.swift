//
//  ScanDecoder.swift
//  PrettySwiftQR
//

import Foundation

/// A successfully scanned payload.
public enum ScanResult: Hashable, Sendable {
    /// A plain (non-UR) code.
    case text(String)
    /// A single- or multi-part UR, reassembled.
    case ur(UR)

    /// The payload as text: the raw string for `.text`, the UTF-8 body for `ur:bytes`.
    public var string: String? {
        switch self {
        case .text(let s): return s
        case .ur(let ur): return ur.utf8String
        }
    }

    /// The payload as bytes: UTF-8 for `.text`, the byte-string body for `ur:bytes`.
    public var data: Data? {
        switch self {
        case .text(let s): return Data(s.utf8)
        case .ur(let ur): return ur.bytes
        }
    }
}

public enum ScanError: Error, Hashable, Sendable, LocalizedError {
    /// Fountain decoding finished but the message checksum did not match.
    case invalidChecksum
    /// The reassembled body was not well-formed CBOR.
    case invalidCBOR
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .invalidChecksum: return "Multi-part code failed its checksum."
        case .invalidCBOR: return "Multi-part code body is not valid CBOR."
        case .other(let s): return s
        }
    }
}

/// Camera-independent state machine that turns scanned strings into results.
///
/// Feed it every code the camera sees. It classifies plain text versus URs,
/// collects multi-part URs, reports exact progress, and never lets a stray code
/// disturb a collection in progress. Drive it from a single isolation domain.
public final class ScanDecoder {
    public struct Configuration: Hashable, Sendable {
        /// Deliver plain (non-UR) codes.
        public var acceptsText = true
        /// Deliver URs (single and multi-part). When false, UR strings are treated as text.
        public var acceptsUR = true
        /// Abandon a multi-part collection that has not accepted a part for this long.
        public var staleTimeout: Duration? = nil

        public init(acceptsText: Bool = true, acceptsUR: Bool = true, staleTimeout: Duration? = nil) {
            self.acceptsText = acceptsText
            self.acceptsUR = acceptsUR
            self.staleTimeout = staleTimeout
        }
    }

    public enum Phase: Hashable, Sendable {
        case idle
        /// Collecting parts of a multi-part UR of the given type.
        case collecting(urType: String)
        case completed(ScanResult)
        case failed(ScanError)
    }

    public enum RejectReason: Hashable, Sendable {
        /// The code type is disabled in the configuration.
        case notAccepted
        /// A plain code arrived while a multi-part UR was being collected.
        case textDuringCollection
        /// A UR part that belongs to a different message or type.
        case foreignPart
        /// A UR string that could not be parsed.
        case malformed
        /// A result was already delivered; call `reset()` to scan again.
        case alreadyCompleted
    }

    /// What happened to one scanned code.
    public enum Outcome: Hashable, Sendable {
        case rejected(RejectReason)
        /// A multi-part part was accepted; decoding continues.
        case progressed(ScanProgress)
        /// A duplicate part of the current collection; nothing changed.
        case duplicate(ScanProgress)
        case completed(ScanResult)
        case failed(ScanError)
        /// The stale timeout elapsed; the collection was reset before this code was processed.
        case timedOut
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .idle
    /// Progress of the current or just-completed collection; nil outside multi-part scans.
    public private(set) var progress: ScanProgress?
    public private(set) var lastAcceptedAt: ContinuousClock.Instant?
    private var urDecoder = URDecoder()
    /// Lower-cased part strings accepted so far; identifies camera re-deliveries exactly.
    private var acceptedParts = Set<String>()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Clears all state. Safe from any phase.
    public func reset() {
        urDecoder = URDecoder()
        acceptedParts.removeAll()
        phase = .idle
        progress = nil
        lastAcceptedAt = nil
    }

    /// Returns `true` and resets if a collection has gone stale.
    @discardableResult
    public func expireIfStale(now: ContinuousClock.Instant = .now) -> Bool {
        guard case .collecting = phase, let timeout = configuration.staleTimeout, let last = lastAcceptedAt else { return false }
        guard now - last > timeout else { return false }
        reset()
        return true
    }

    /// Feeds one scanned string.
    public func receive(_ rawCode: String, now: ContinuousClock.Instant = .now) -> Outcome {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if expireIfStale(now: now) {
            // Process this code against the fresh state, but tell the caller why progress vanished.
            _ = receive(code, now: now)
            return .timedOut
        }

        switch phase {
        case .completed:
            return .rejected(.alreadyCompleted)
        case .failed:
            return .rejected(.alreadyCompleted)
        case .idle, .collecting:
            break
        }

        let isUR = configuration.acceptsUR && URDecoder.isURString(code)
        guard isUR else {
            guard configuration.acceptsText else { return .rejected(.notAccepted) }
            if case .collecting = phase { return .rejected(.textDuringCollection) }
            let result = ScanResult.text(code)
            phase = .completed(result)
            return .completed(result)
        }

        switch urDecoder.receive(code) {
        case .rejected:
            if case .collecting = phase { return .rejected(.foreignPart) }
            return .rejected(.malformed)

        case .accepted:
            lastAcceptedAt = now
            let isNew = acceptedParts.insert(code.lowercased()).inserted
            let progress = ScanProgress(decoder: urDecoder, uniqueParts: acceptedParts.count)
            self.progress = progress
            phase = .collecting(urType: urDecoder.expectedType ?? "")
            return isNew ? .progressed(progress) : .duplicate(progress)

        case .completed:
            lastAcceptedAt = now
            acceptedParts.insert(code.lowercased())
            if urDecoder.expectedFragmentCount != nil {
                progress = ScanProgress(decoder: urDecoder, uniqueParts: acceptedParts.count)
            }
            switch urDecoder.result {
            case .success(let ur)?:
                let result = ScanResult.ur(ur)
                phase = .completed(result)
                return .completed(result)
            case .failure(let error)?:
                let scanError: ScanError
                if let fountainError = error as? FountainDecoderError, fountainError == .invalidChecksum {
                    scanError = .invalidChecksum
                } else if let urError = error as? URError, urError == .invalidCBOR {
                    scanError = .invalidCBOR
                } else {
                    scanError = .other(error.localizedDescription)
                }
                phase = .failed(scanError)
                return .failed(scanError)
            case nil:
                return .rejected(.malformed)
            }
        }
    }
}
