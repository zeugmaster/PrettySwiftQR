//
//  CameraCodeSource.swift
//  PrettySwiftQR
//

#if os(iOS)
@preconcurrency import AVFoundation
import os

/// Hardware QR detection through `AVCaptureMetadataOutput`.
///
/// Configuration and start/stop run on a private queue; nothing blocks the
/// main thread. Create one, hand it to `QRScanner`, and show `CameraPreview`.
public final class CameraCodeSource: NSObject, CodeSource, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    public enum Position: Sendable, Hashable {
        case back, front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PrettySwiftQR.camera", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(uncheckedState: MutableState())

    private struct MutableState {
        var continuation: AsyncStream<ScannedCode>.Continuation?
        var configured = false
        var device: AVCaptureDevice?
        var position: Position = .back
        var input: AVCaptureDeviceInput?
    }

    public init(position: Position = .back) {
        super.init()
        state.withLockUnchecked { $0.position = position }
    }

    /// The device currently feeding the session, once configured.
    public var currentDevice: AVCaptureDevice? {
        state.withLockUnchecked { $0.device }
    }

    public var position: Position {
        state.withLockUnchecked { $0.position }
    }

    // MARK: CodeSource

    public func start() async throws -> AsyncStream<ScannedCode> {
        #if targetEnvironment(simulator)
        throw CodeSourceError.unavailable
        #else
        try await requestAccess()
        try await configureIfNeeded()
        let (stream, continuation) = AsyncStream<ScannedCode>.makeStream(bufferingPolicy: .bufferingNewest(8))
        state.withLockUnchecked {
            $0.continuation?.finish()
            $0.continuation = continuation
        }
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if !session.isRunning { session.startRunning() }
                done.resume()
            }
        }
        return stream
        #endif
    }

    public func stop() async {
        state.withLockUnchecked {
            $0.continuation?.finish()
            $0.continuation = nil
        }
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if session.isRunning { session.stopRunning() }
                done.resume()
            }
        }
    }

    // MARK: Controls

    /// Switches between the back and front camera. No-op before `start()`.
    public func setPosition(_ position: Position) async throws {
        guard state.withLockUnchecked({ $0.configured }) else {
            state.withLockUnchecked { $0.position = position }
            return
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.swapInput(to: position)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    public var hasTorch: Bool {
        currentDevice?.hasTorch ?? false
    }

    public func setTorch(_ on: Bool) {
        guard let device = currentDevice, device.hasTorch else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                // Torch is best-effort.
            }
        }
    }

    // MARK: Setup

    private func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CodeSourceError.unauthorized }
        default:
            throw CodeSourceError.unauthorized
        }
    }

    private func configureIfNeeded() async throws {
        guard !state.withLockUnchecked({ $0.configured }) else { return }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private func configure() throws {
        let position = state.withLockUnchecked { $0.position }
        guard let device = Self.device(for: position) ?? AVCaptureDevice.default(for: .video) else {
            throw CodeSourceError.unavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CodeSourceError.configurationFailed(error.localizedDescription)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input) else { throw CodeSourceError.configurationFailed("cannot add camera input") }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw CodeSourceError.configurationFailed("cannot add metadata output") }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { throw CodeSourceError.configurationFailed("QR detection unsupported") }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: queue)

        state.withLockUnchecked {
            $0.configured = true
            $0.device = device
            $0.input = input
        }
    }

    private func swapInput(to position: Position) throws {
        guard let device = Self.device(for: position) else { throw CodeSourceError.unavailable }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let old = state.withLockUnchecked({ $0.input }) { session.removeInput(old) }
        guard session.canAddInput(newInput) else { throw CodeSourceError.configurationFailed("cannot add camera input") }
        session.addInput(newInput)
        state.withLockUnchecked {
            $0.device = device
            $0.input = newInput
            $0.position = position
        }
    }

    private static func device(for position: Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position.avPosition).devices.first
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let continuation = state.withLockUnchecked({ $0.continuation }) else { return }
        let now = ContinuousClock.now
        let codes = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .filter { $0.type == .qr }
            .compactMap { object -> ScannedCode? in
                guard let value = object.stringValue, !value.isEmpty else { return nil }
                return ScannedCode(value: value, bounds: object.bounds, timestamp: now)
            }
            .sorted { ($0.bounds?.width ?? 0) * ($0.bounds?.height ?? 0) > ($1.bounds?.width ?? 0) * ($1.bounds?.height ?? 0) }
        for code in codes {
            continuation.yield(code)
        }
    }
}
#endif
