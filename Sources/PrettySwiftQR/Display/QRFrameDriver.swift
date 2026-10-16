//
//  QRFrameDriver.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// Owns the frame encoder off the main actor so QR encoding never blocks the UI.
actor QRFrameProducer {
    private let encoder: QRFrameEncoder

    init(payload: QRPayload, errorCorrection: QRErrorCorrection?) throws {
        encoder = try QRFrameEncoder(payload: payload, errorCorrection: errorCorrection)
    }

    var isAnimated: Bool { encoder.isAnimated }
    var fragmentCount: Int { encoder.fragmentCount }
    var version: Int { encoder.version }

    struct Frame: Sendable {
        let matrix: QRMatrix
        let sequenceNumber: UInt32
        let fragmentIndexes: Set<Int>
    }

    func next() throws -> Frame {
        let matrix = try encoder.nextFrame()
        return Frame(matrix: matrix, sequenceNumber: encoder.sequenceNumber, fragmentIndexes: encoder.lastFragmentIndexes)
    }

    func restart() {
        encoder.restart()
    }
}

/// Main-actor state behind `QRCodeView`: the current frame and playback.
@MainActor
@Observable
public final class QRFrameDriver {
    public private(set) var matrix: QRMatrix?
    public private(set) var error: Error?
    public private(set) var isAnimated = false
    /// Number of fountain fragments (1 for static codes).
    public private(set) var fragmentCount = 1
    /// Sequence number of the frame on screen (1-based).
    public private(set) var sequenceNumber: UInt32 = 0
    /// Fragments mixed into the frame on screen.
    public private(set) var fragmentIndexes: Set<Int> = []
    public private(set) var version = 0
    /// The payload whose frames are on screen. Changes exactly when `matrix` switches payloads.
    public private(set) var loadedPayload: QRPayload?
    /// Increments whenever `matrix` switches to another payload (or to an error).
    /// `QRCodeView` observes it to choreograph the cross-reveal.
    public private(set) var swapGeneration = 0
    /// The last frame of the payload that was on screen before the latest swap.
    public private(set) var previousMatrix: QRMatrix?

    private var producer: QRFrameProducer?
    private var loadedKey: LoadKey?

    private struct LoadKey: Equatable {
        let payload: QRPayload
        let errorCorrection: QRErrorCorrection?
    }

    public init() {}

    /// Encodes `payload` (if not already loaded) and shows its first frame.
    /// The previous frame stays on screen until the new one is ready, then
    /// `matrix`, `previousMatrix` and `swapGeneration` change together so a
    /// view can cross-reveal the two. The swap itself is not animated here.
    /// - Returns: true when a different payload (or an error) was swapped in,
    ///   false when the payload was already loaded and merely restarted.
    @discardableResult
    public func load(_ payload: QRPayload, errorCorrection: QRErrorCorrection?) async -> Bool {
        let key = LoadKey(payload: payload, errorCorrection: errorCorrection)
        if loadedKey == key, producer != nil {
            await producer?.restart()
            await advance()
            return false
        }
        loadedKey = key
        do {
            let producer = try await Task.detached(priority: .userInitiated) {
                try QRFrameProducer(payload: payload, errorCorrection: errorCorrection)
            }.value
            guard loadedKey == key else { return false } // superseded by a newer load
            let animated = await producer.isAnimated
            let count = await producer.fragmentCount
            let version = await producer.version
            let frame = try await producer.next()
            withTransaction(Transaction()) {
                self.previousMatrix = self.matrix
                self.producer = producer
                self.isAnimated = animated
                self.fragmentCount = count
                self.version = version
                self.error = nil
                self.matrix = frame.matrix
                self.sequenceNumber = frame.sequenceNumber
                self.fragmentIndexes = frame.fragmentIndexes
                self.loadedPayload = payload
                self.swapGeneration += 1
            }
        } catch {
            guard loadedKey == key else { return false }
            withTransaction(Transaction()) {
                self.previousMatrix = self.matrix
                self.error = error
                self.producer = nil
                self.matrix = nil
                self.loadedPayload = payload
                self.swapGeneration += 1
            }
        }
        return true
    }

    /// Advances to the next frame. No-op for static codes after the first frame.
    public func advance() async {
        guard let producer else { return }
        do {
            let frame = try await producer.next()
            // A plain, animation-free transaction. The matrix is not animatable, so
            // no ambient animation can interpolate frames. `disablesAnimations` must
            // NOT be used here: it cancels in-flight animations on the views it
            // touches, which would snap a running reveal to its end state.
            withTransaction(Transaction()) {
                matrix = frame.matrix
                sequenceNumber = frame.sequenceNumber
                fragmentIndexes = frame.fragmentIndexes
            }
        } catch {
            self.error = error
        }
    }

    /// Plays frames at `framesPerSecond` until cancelled. Static codes return immediately.
    public func play(framesPerSecond: Double) async {
        guard isAnimated, producer != nil else { return }
        let interval = Duration.seconds(1 / max(0.5, framesPerSecond))
        let clock = ContinuousClock()
        var next = clock.now + interval
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: next)
            } catch {
                return
            }
            await advance()
            next += interval
            if next < clock.now { next = clock.now + interval }
        }
    }
}
