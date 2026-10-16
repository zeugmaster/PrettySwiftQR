//
//  UREncoder.swift
//
//  Copyright © 2020 by Blockchain Commons, LLC
//  Licensed under the "BSD-2-Clause Plus Patent License"
//
//  Vendored into PrettySwiftQR.
//

import Foundation

public final class UREncoder {
    /// Encode a single-part UR.
    public static func encode(_ ur: UR) -> String {
        let body = Bytewords.encode(ur.cbor, style: .minimal)
        return encodeUR([ur.type, body])
    }

    public static func checksumWords(_ ur: UR, style: Bytewords.Style = .standard) -> String {
        Bytewords.checksumWords(ur.cbor, style: style)
    }

    public let ur: UR
    private let fountainEncoder: FountainEncoder

    public var messageLen: Int { fountainEncoder.messageLen }
    public var fragmentLen: Int { fountainEncoder.fragmentLen }
    public var maxFragmentLen: Int { fountainEncoder.maxFragmentLen }
    public var seqNum: UInt32 { fountainEncoder.seqNum }
    public var seqLen: Int { fountainEncoder.seqLen }
    public var lastFragmentIndexes: Set<Int> { fountainEncoder.lastFragmentIndexes ?? [] }

    /// Start encoding a (possibly) multi-part UR.
    public init(_ ur: UR, maxFragmentLen: Int, firstSeqNum: UInt32 = 0, minFragmentLen: Int = 10) {
        self.ur = ur
        fountainEncoder = FountainEncoder(message: ur.cbor, maxFragmentLen: maxFragmentLen, firstSeqNum: firstSeqNum, minFragmentLen: minFragmentLen)
    }

    /// `true` if the minimum number of parts to relay the complete message have been generated.
    public var isComplete: Bool { fountainEncoder.isComplete }

    /// `true` if this UR can be contained in a single part.
    public var isSinglePart: Bool { fountainEncoder.isSinglePart }

    public var messagePercentOfMaxFragmentLen: Double {
        fountainEncoder.messagePercentOfMaxFragmentLen
    }

    public func nextPart() -> String {
        let part = fountainEncoder.nextPart()
        if isSinglePart {
            return Self.encode(ur)
        } else {
            return Self.encodePart(type: ur.type, part: part)
        }
    }

    /// Rewinds so the next part is the first simple part again.
    public func restart(firstSeqNum: UInt32 = 0) {
        fountainEncoder.restart(firstSeqNum: firstSeqNum)
    }

    private static func encodePart(type: String, part: FountainEncoder.Part) -> String {
        let seq = "\(part.seqNum)-\(part.seqLen)"
        let body = Bytewords.encode(part.cbor, style: .minimal)
        return encodeUR([type, seq, body])
    }

    private static func encodeURI(scheme: String, pathComponents: [String]) -> String {
        let path = pathComponents.joined(separator: "/")
        return [scheme, path].joined(separator: ":")
    }

    private static func encodeUR(_ pathComponents: [String]) -> String {
        encodeURI(scheme: "ur", pathComponents: pathComponents)
    }
}
