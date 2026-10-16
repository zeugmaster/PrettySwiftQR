//
//  ScanProgress.swift
//  PrettySwiftQR
//

import Foundation

/// Exact progress of a multi-part (fountain-coded) scan.
public struct ScanProgress: Hashable, Sendable {
    /// Number of source fragments the message was split into.
    public let expectedFragments: Int
    /// Number of distinct source fragments recovered so far.
    public let receivedFragments: Int
    /// Parts accepted by the decoder, duplicates excluded.
    public let processedParts: Int
    /// Mixed (XORed) parts held that could not be reduced yet. Latent information.
    public let pendingMixedParts: Int
    /// Fragments contained in the most recently accepted part.
    public let lastFragmentIndexes: Set<Int>
    /// Indexes of recovered fragments.
    public let receivedFragmentIndexes: Set<Int>
    public let isComplete: Bool

    public init(expectedFragments: Int, receivedFragments: Int, processedParts: Int, pendingMixedParts: Int, lastFragmentIndexes: Set<Int>, receivedFragmentIndexes: Set<Int>, isComplete: Bool) {
        self.expectedFragments = expectedFragments
        self.receivedFragments = receivedFragments
        self.processedParts = processedParts
        self.pendingMixedParts = pendingMixedParts
        self.lastFragmentIndexes = lastFragmentIndexes
        self.receivedFragmentIndexes = receivedFragmentIndexes
        self.isComplete = isComplete
    }

    init(decoder: URDecoder, uniqueParts: Int) {
        let expected = decoder.expectedFragmentCount ?? 0
        let complete: Bool
        if case .success? = decoder.result { complete = true } else { complete = false }
        self.init(
            expectedFragments: expected,
            receivedFragments: complete ? expected : decoder.receivedFragmentIndexes.count,
            processedParts: uniqueParts,
            pendingMixedParts: decoder.pendingMixedPartsCount,
            lastFragmentIndexes: decoder.lastFragmentIndexes,
            receivedFragmentIndexes: complete ? Set(0..<expected) : decoder.receivedFragmentIndexes,
            isComplete: complete
        )
    }

    /// `receivedFragments / expectedFragments`. Exactly 1 when complete, never above.
    public var fraction: Double {
        if isComplete { return 1 }
        guard expectedFragments > 0 else { return 0 }
        return min(1, Double(receivedFragments) / Double(expectedFragments))
    }

    /// Per-fragment state for a fragment bar.
    public enum FragmentState: Hashable, Sendable {
        case missing
        case received
        /// Received and part of the most recent frame.
        case justReceived
        /// Not yet recovered but present in the most recent (mixed) frame.
        case inLastFrame
    }

    public var fragmentStates: [FragmentState] {
        (0..<expectedFragments).map { index in
            let received = receivedFragmentIndexes.contains(index)
            let inLast = lastFragmentIndexes.contains(index)
            switch (received, inLast) {
            case (true, true): return .justReceived
            case (true, false): return .received
            case (false, true): return .inLastFrame
            case (false, false): return .missing
            }
        }
    }

    public static let none = ScanProgress(expectedFragments: 0, receivedFragments: 0, processedParts: 0, pendingMixedParts: 0, lastFragmentIndexes: [], receivedFragmentIndexes: [], isComplete: false)
}
