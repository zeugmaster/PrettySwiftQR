//
//  QRScanner.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// Drives a `CodeSource` through a `ScanDecoder` and publishes state for SwiftUI.
///
/// One object, one `reset()`. Static and animated codes are handled alike;
/// the decoder decides. Observe `state` and `progress`, or set `onResult`.
@MainActor
@Observable
public final class QRScanner {
    public struct Configuration: Sendable {
        public var decoder: ScanDecoder.Configuration
        /// The same code value is delivered again only after this interval.
        public var rescanInterval: Duration
        /// Stop processing codes after a result until `reset()` or `resume(after:)`.
        public var holdsResult: Bool
        /// How often to check the stale timeout while collecting.
        public var staleCheckInterval: Duration

        public init(decoder: ScanDecoder.Configuration = ScanDecoder.Configuration(), rescanInterval: Duration = .seconds(1), holdsResult: Bool = true, staleCheckInterval: Duration = .milliseconds(500)) {
            self.decoder = decoder
            self.rescanInterval = rescanInterval
            self.holdsResult = holdsResult
            self.staleCheckInterval = staleCheckInterval
        }
    }

    public enum State: Hashable, Sendable {
        case idle
        case starting
        case unauthorized
        case unavailable
        case scanning
        case completed(ScanResult)
        case failed(ScanError)

        public var isRunning: Bool {
            switch self {
            case .scanning, .completed, .failed: return true
            case .idle, .starting, .unauthorized, .unavailable: return false
            }
        }
    }

    public private(set) var state: State = .idle
    /// Progress of the current multi-part collection; nil otherwise.
    public private(set) var progress: ScanProgress?
    /// Why the most recent code was rejected, for diagnostics.
    public private(set) var lastRejection: ScanDecoder.RejectReason?
    /// Number of codes the source delivered since `start()`.
    public private(set) var receivedCodeCount = 0
    public var configuration: Configuration
    public let source: any CodeSource
    /// Called on the main actor whenever a result is produced.
    public var onResult: ((ScanResult) -> Void)?
    /// Called when a multi-part collection times out.
    public var onStale: (() -> Void)?

    private var decoder: ScanDecoder
    private var streamTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var lastDelivery: [String: ContinuousClock.Instant] = [:]
    private var sourceRunning = false

    public init(configuration: Configuration = Configuration(), source: any CodeSource) {
        self.configuration = configuration
        self.source = source
        self.decoder = ScanDecoder(configuration: configuration.decoder)
    }

    /// Starts the source. Safe to call repeatedly.
    public func start() async {
        guard !sourceRunning, state != .starting else { return }
        state = .starting
        do {
            let stream = try await source.start()
            sourceRunning = true
            decoder = ScanDecoder(configuration: configuration.decoder)
            progress = nil
            lastDelivery.removeAll()
            state = .scanning
            streamTask = Task { [weak self] in
                for await code in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(code)
                }
            }
            startStaleTicker()
        } catch CodeSourceError.unauthorized {
            state = .unauthorized
        } catch CodeSourceError.unavailable {
            state = .unavailable
        } catch {
            state = .failed(.other(error.localizedDescription))
        }
    }

    /// Stops the source and returns to `.idle`, keeping nothing.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        staleTask?.cancel()
        staleTask = nil
        if sourceRunning {
            await source.stop()
            sourceRunning = false
        }
        state = .idle
        progress = nil
    }

    /// Clears decoder state, de-duplication and any held result. Safe from any state.
    public func reset() {
        decoder.reset()
        progress = nil
        lastRejection = nil
        lastDelivery.removeAll()
        if state.isRunning { state = .scanning }
    }

    /// Waits, then `reset()`s. Mirrors macadamia's "retry after" flow.
    public func resume(after delay: Duration) async {
        try? await Task.sleep(for: delay)
        reset()
    }

    /// Feeds a code as if the source had delivered it.
    public func handle(_ code: ScannedCode) {
        receivedCodeCount += 1
        guard case .scanning = state else { return }

        let now = code.timestamp
        if let last = lastDelivery[code.value], now - last < configuration.rescanInterval {
            return
        }
        lastDelivery[code.value] = now
        if lastDelivery.count > 512 { lastDelivery.removeAll() }

        if decoder.expireIfStale(now: now) {
            progress = nil
            onStale?()
        }

        switch decoder.receive(code.value, now: now) {
        case .completed(let result):
            progress = decoder.progress
            lastRejection = nil
            if configuration.holdsResult {
                state = .completed(result)
            } else {
                decoder.reset()
            }
            onResult?(result)
        case .progressed(let p), .duplicate(let p):
            progress = p
            lastRejection = nil
        case .failed(let error):
            progress = decoder.progress
            state = .failed(error)
        case .rejected(let reason):
            lastRejection = reason
        case .timedOut:
            progress = decoder.progress
            onStale?()
        }
    }

    private func startStaleTicker() {
        staleTask?.cancel()
        guard configuration.decoder.staleTimeout != nil else { return }
        let interval = configuration.staleCheckInterval
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                if self.decoder.expireIfStale() {
                    self.progress = nil
                    self.onStale?()
                }
            }
        }
    }
}

public extension QRScanner {
    /// A scanner on the device camera (back camera by default).
    /// On platforms without camera scanning the source is always unavailable.
    convenience init(configuration: Configuration = Configuration()) {
        #if os(iOS)
        self.init(configuration: configuration, source: CameraCodeSource())
        #else
        self.init(configuration: configuration, source: UnavailableCodeSource())
        #endif
    }

    #if os(iOS)
    var camera: CameraCodeSource? { source as? CameraCodeSource }
    #endif
}
