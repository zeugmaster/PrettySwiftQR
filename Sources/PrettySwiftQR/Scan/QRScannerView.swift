//
//  QRScannerView.swift
//  PrettySwiftQR
//

#if os(iOS)
import SwiftUI
import PrettyQRCore

/// Camera preview plus scanning, with an overlay you compose from the scanner's state.
///
/// ```swift
/// QRScannerView { result in handle(result) }
/// ```
/// or, for full control:
/// ```swift
/// @State private var scanner = QRScanner()
/// QRScannerView(scanner: scanner) { scanner in
///     ScanProgressRing(progress: scanner.progress, state: scanner.state) { scanner.reset() }
/// }
/// ```
/// The view starts the camera on appear, stops it on disappear and while the
/// scene is in the background, and resumes afterwards.
public struct QRScannerView<Overlay: View, Unavailable: View>: View {
    private let scanner: QRScanner
    private let overlay: (QRScanner) -> Overlay
    private let unavailable: (QRScanner.State) -> Unavailable

    @Environment(\.scenePhase) private var scenePhase
    @State private var isActive = true

    public init(scanner: QRScanner, @ViewBuilder overlay: @escaping (QRScanner) -> Overlay, @ViewBuilder unavailable: @escaping (QRScanner.State) -> Unavailable) {
        self.scanner = scanner
        self.overlay = overlay
        self.unavailable = unavailable
    }

    public var body: some View {
        ZStack {
            switch scanner.state {
            case .unauthorized, .unavailable:
                unavailable(scanner.state)
            default:
                if let camera = scanner.camera {
                    CameraPreview(source: camera)
                        .ignoresSafeArea(.all, edges: [])
                } else {
                    Color.black
                }
                overlay(scanner)
            }
        }
        .task(id: isActive) {
            if isActive {
                await scanner.start()
            } else {
                await scanner.stop()
            }
        }
        .onDisappear {
            Task { await scanner.stop() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            isActive = phase != .background
        }
    }
}

public extension QRScannerView where Unavailable == QRScannerUnavailableView {
    init(scanner: QRScanner, @ViewBuilder overlay: @escaping (QRScanner) -> Overlay) {
        self.init(scanner: scanner, overlay: overlay) { state in QRScannerUnavailableView(state: state) }
    }
}

public extension QRScannerView where Overlay == QRScannerDefaultOverlay, Unavailable == QRScannerUnavailableView {
    /// Owns a camera scanner and shows the default progress ring.
    init(configuration: QRScanner.Configuration = QRScanner.Configuration(), onResult: @escaping (ScanResult) -> Void) {
        let scanner = QRScanner(configuration: configuration)
        scanner.onResult = onResult
        self.init(scanner: scanner, overlay: { QRScannerDefaultOverlay(scanner: $0) }, unavailable: { QRScannerUnavailableView(state: $0) })
    }
}

/// Progress ring in the bottom-left corner; tapping it resets an in-flight scan.
public struct QRScannerDefaultOverlay: View {
    let scanner: QRScanner

    public init(scanner: QRScanner) { self.scanner = scanner }

    public var body: some View {
        VStack {
            Spacer()
            HStack {
                ScanProgressRing(progress: scanner.progress, state: scanner.state) {
                    scanner.reset()
                }
                .padding()
                Spacer()
            }
        }
    }
}

public struct QRScannerUnavailableView: View {
    let state: QRScanner.State

    public init(state: QRScanner.State) { self.state = state }

    public var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: state == .unauthorized ? "camera.fill.badge.ellipsis" : "camera.slash")
                    .font(.largeTitle)
                Text(state == .unauthorized ? "Allow camera access in Settings to scan codes." : "No camera is available on this device.")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding()
        }
    }
}
#endif
