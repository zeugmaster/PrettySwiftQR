//
//  CameraPreview.swift
//  PrettySwiftQR
//

#if os(iOS)
import SwiftUI
import AVFoundation

/// Live camera preview for a `CameraCodeSource`, rotation handled.
public struct CameraPreview: UIViewRepresentable {
    private let source: CameraCodeSource
    private let videoGravity: AVLayerVideoGravity
    private let device: AVCaptureDevice?

    public init(source: CameraCodeSource, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.source = source
        self.videoGravity = videoGravity
        self.device = source.currentDevice
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = source.session
        view.previewLayer.videoGravity = videoGravity
        view.attachRotation(to: device)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.videoGravity = videoGravity
        uiView.attachRotation(to: device ?? source.currentDevice)
    }

    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var attachedDevice: AVCaptureDevice?

        func attachRotation(to device: AVCaptureDevice?) {
            guard let device, device != attachedDevice else { return }
            attachedDevice = device
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyRotation(angle) }
            }
        }

        private func applyRotation(_ angle: CGFloat) {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}
#endif
