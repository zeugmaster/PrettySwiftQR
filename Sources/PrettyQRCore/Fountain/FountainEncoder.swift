//
//  FountainEncoder.swift
//
//  Copyright © 2020 by Blockchain Commons, LLC
//  Licensed under the "BSD-2-Clause Plus Patent License"
//
//  Vendored into PrettySwiftQR. The DCBOR dependency was replaced by MiniCBOR;
//  the wire format is unchanged.
//

import Foundation

public enum FountainEncoderError: LocalizedError, Sendable {
    case invalidPartHeader

    public var errorDescription: String? {
        switch self {
        case .invalidPartHeader:
            return "FountainEncoder: Invalid part header."
        }
    }
}

public final class FountainEncoder {
    public let messageLen: Int
    public let fragmentLen: Int
    public let maxFragmentLen: Int
    public var seqNum: UInt32
    public var seqLen: Int { fragments.count }
    public private(set) var lastFragmentIndexes: FragmentIndexes!

    let checksum: UInt32
    let fragments: [Data]
    let fragmentChooser: FragmentChooser

    /// This becomes `true` when the minimum number of parts
    /// to relay the complete message have been generated
    public var isComplete: Bool { seqNum >= seqLen }

    /// True if only a single part will be generated.
    public var isSinglePart: Bool { seqLen == 1 }

    public var messagePercentOfMaxFragmentLen: Double {
        Double(maxFragmentLen) / Double(messageLen)
    }

    public struct Part: CustomStringConvertible, Codable, Hashable, Sendable {
        public let seqNum: UInt32
        public let seqLen: Int
        public let messageLen: Int
        public let checksum: UInt32
        public let data: Data

        public init(seqNum: UInt32, seqLen: Int, messageLen: Int, checksum: UInt32, data: Data) {
            self.seqNum = seqNum
            self.seqLen = seqLen
            self.messageLen = messageLen
            self.checksum = checksum
            self.data = data
        }

        /// Parses the CBOR part header `[seqNum, seqLen, messageLen, checksum, data]`.
        public init(cbor: Data) throws {
            var reader = MiniCBOR.Reader(cbor)
            guard
                let count = try? reader.readArrayHeader(), count == 5,
                let seqNum = try? reader.readUnsigned(), seqNum <= UInt64(UInt32.max),
                let seqLen = try? reader.readUnsigned(), seqLen <= UInt64(Int.max),
                let messageLen = try? reader.readUnsigned(), messageLen <= UInt64(Int.max),
                let checksum = try? reader.readUnsigned(), checksum <= UInt64(UInt32.max),
                let data = try? reader.readBytes(),
                reader.isAtEnd
            else {
                throw FountainEncoderError.invalidPartHeader
            }
            self.init(seqNum: UInt32(seqNum), seqLen: Int(seqLen), messageLen: Int(messageLen), checksum: UInt32(checksum), data: data)
        }

        public var description: String {
            "seqNum:\(seqNum), seqLen:\(seqLen), messageLen:\(messageLen), checksum:\(checksum), data:\(data.hex)"
        }

        public var cbor: Data {
            var writer = MiniCBOR.Writer()
            writer.writeArrayHeader(count: 5)
            writer.writeUnsigned(UInt64(seqNum))
            writer.writeUnsigned(UInt64(seqLen))
            writer.writeUnsigned(UInt64(messageLen))
            writer.writeUnsigned(UInt64(checksum))
            writer.writeBytes(data)
            return writer.data
        }
    }

    public init(message: Data, maxFragmentLen: Int? = nil, firstSeqNum: UInt32 = 0, minFragmentLen: Int = 10) {
        assert(message.count <= UInt32.max)
        self.messageLen = message.count
        self.checksum = CRC32.checksum(message)
        self.maxFragmentLen = maxFragmentLen ?? message.count
        self.fragmentLen = Self.findNominalFragmentLength(messageLen: message.count, minFragmentLen: minFragmentLen, maxFragmentLen: self.maxFragmentLen)
        self.fragments = Self.partitionMessage(message, fragmentLen: fragmentLen)
        self.seqNum = firstSeqNum
        fragmentChooser = FragmentChooser(seqLen: fragments.count, checksum: checksum)
    }

    public func nextPart() -> Part {
        seqNum &+= 1
        assert(seqLen > 1 || seqNum == 1)
        // Choose the fragments, and let the caller interrogate which fragments were chosen for debugging or feedback
        lastFragmentIndexes = fragmentChooser.chooseFragments(at: seqNum)
        let mixed = mix(fragmentIndexes: lastFragmentIndexes)
        return Part(seqNum: seqNum, seqLen: seqLen, messageLen: messageLen, checksum: checksum, data: mixed)
    }

    /// Rewinds the encoder so the next part is the first simple part again.
    public func restart(firstSeqNum: UInt32 = 0) {
        seqNum = firstSeqNum
        lastFragmentIndexes = nil
    }

    private func mix(fragmentIndexes: FragmentIndexes) -> Data {
        if fragmentIndexes.count == 1 {
            return fragments[fragmentIndexes.first!]
        } else {
            return fragmentIndexes.reduce(into: Data(repeating: 0, count: fragmentLen)) { result, index in
                fragments[index].xor(into: &result)
            }
        }
    }

    static func partitionMessage(_ message: Data, fragmentLen: Int) -> [Data] {
        var remaining = message
        var fragments: [Data] = []
        while !remaining.isEmpty {
            var fragment = remaining.prefix(fragmentLen)
            remaining.removeFirst(fragment.count)
            let padding = fragmentLen - fragment.count
            if padding > 0 {
                fragment.append(Data(repeating: 0, count: padding))
            }
            fragments.append(fragment)
        }
        return fragments
    }

    static func findNominalFragmentLength(messageLen: Int, minFragmentLen: Int, maxFragmentLen: Int) -> Int {
        precondition(messageLen > 0)
        precondition(minFragmentLen > 0)
        precondition(maxFragmentLen >= minFragmentLen)
        let maxFragmentCount = messageLen / minFragmentLen
        var fragmentLen: Int!
        for fragmentCount in 1 ... max(1, maxFragmentCount) {
            fragmentLen = Int(ceil(Double(messageLen) / Double(fragmentCount)))
            if fragmentLen <= maxFragmentLen {
                break
            }
        }
        return fragmentLen
    }
}
