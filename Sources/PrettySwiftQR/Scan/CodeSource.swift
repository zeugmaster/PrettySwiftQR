//
//  CodeSource.swift
//  PrettySwiftQR
//

import Foundation
import CoreGraphics

/// One code seen by a source.
public struct ScannedCode: Hashable, Sendable {
    public let value: String
    /// Bounding box in the source's normalised coordinate space (0…1), if known.
    public let bounds: CGRect?
    public let timestamp: ContinuousClock.Instant

    public init(value: String, bounds: CGRect? = nil, timestamp: ContinuousClock.Instant = .now) {
        self.value = value
        self.bounds = bounds
        self.timestamp = timestamp
    }
}

public enum CodeSourceError: Error, Hashable, Sendable, LocalizedError {
    case unauthorized
    case unavailable
    case configurationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Camera access was not granted."
        case .unavailable: return "No camera is available."
        case .configurationFailed(let reason): return "Camera setup failed: \(reason)"
        }
    }
}

/// Anything that produces scanned code strings: the camera, a test script, a file.
public protocol CodeSource: AnyObject, Sendable {
    /// Begins delivery. The stream finishes when `stop()` is called.
    func start() async throws -> AsyncStream<ScannedCode>
    func stop() async
}

/// A source you feed by hand. Used by tests, previews and custom pipelines.
public final class ManualCodeSource: CodeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ScannedCode>.Continuation?
    private var _isStarted = false

    public init() {}

    public var isStarted: Bool { lock.withLock { _isStarted } }

    public func start() async throws -> AsyncStream<ScannedCode> {
        let (stream, continuation) = AsyncStream<ScannedCode>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
            _isStarted = true
        }
        return stream
    }

    public func stop() async {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            _isStarted = false
        }
    }

    /// Delivers one code. Ignored when not started.
    public func send(_ value: String, bounds: CGRect? = nil, timestamp: ContinuousClock.Instant = .now) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(ScannedCode(value: value, bounds: bounds, timestamp: timestamp))
    }

    public func send(_ code: ScannedCode) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(code)
    }
}

/// Replays a list of codes with a fixed interval, looping if asked. Handy in
/// the simulator, where there is no camera.
public final class ScriptedCodeSource: CodeSource, @unchecked Sendable {
    private let codes: [String]
    private let interval: Duration
    private let loops: Bool
    private let manual = ManualCodeSource()
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(codes: [String], interval: Duration = .milliseconds(100), loops: Bool = true) {
        self.codes = codes
        self.interval = interval
        self.loops = loops
    }

    /// Scripts the frames of `payload` exactly as `QRCodeView` would show them.
    public convenience init(payload: QRPayload, interval: Duration = .milliseconds(100), frames: Int = 200) throws {
        let encoder = try QRFrameEncoder(payload: payload)
        var codes: [String] = []
        if let ur = payload.ur, encoder.isAnimated {
            let urEncoder = UREncoder(ur, maxFragmentLen: payload.maxFragmentLength ?? QRPayload.defaultMaxFragmentLength)
            codes = (0..<frames).map { _ in urEncoder.nextPart().uppercased() }
        } else {
            switch payload {
            case .text(let s): codes = [s]
            case .data(let d): codes = [String(decoding: d, as: UTF8.self)]
            default: codes = [payload.ur!.qrString]
            }
        }
        self.init(codes: codes, interval: interval, loops: true)
    }

    public func start() async throws -> AsyncStream<ScannedCode> {
        let stream = try await manual.start()
        let codes = self.codes, interval = self.interval, loops = self.loops, manual = self.manual
        let task = Task {
            repeat {
                for code in codes {
                    guard !Task.isCancelled else { return }
                    manual.send(code)
                    try? await Task.sleep(for: interval)
                }
            } while loops && !Task.isCancelled
        }
        lock.withLock { self.task?.cancel(); self.task = task }
        return stream
    }

    public func stop() async {
        lock.withLock { task?.cancel(); task = nil }
        await manual.stop()
    }
}

/// Always reports that no camera exists. Default on platforms without camera scanning.
public final class UnavailableCodeSource: CodeSource, Sendable {
    public init() {}
    public func start() async throws -> AsyncStream<ScannedCode> { throw CodeSourceError.unavailable }
    public func stop() async {}
}
