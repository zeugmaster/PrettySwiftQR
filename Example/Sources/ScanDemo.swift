import SwiftUI
import PrettySwiftQR

/// Camera scanning with the default overlay, a result sheet, and a scripted
/// source so the scan pipeline can be exercised in the simulator.
struct ScanDemo: View {
    @State private var scanner = QRScanner(configuration: .init(decoder: .init(staleTimeout: .seconds(8))))
    @State private var simulated: QRScanner?
    @State private var result: ScanResult?
    @State private var torch = false

    private var active: QRScanner { simulated ?? scanner }

    var body: some View {
        NavigationStack {
            ZStack {
                if let simulated {
                    Color.black.ignoresSafeArea()
                    SimulatedScanOverlay(scanner: simulated)
                        .task { await simulated.start() }
                        .onDisappear { Task { await simulated.stop() } }
                } else {
                    QRScannerView(scanner: scanner) { scanner in
                        overlay(for: scanner)
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationTitle("Scan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(simulated == nil ? "Simulate" : "Camera") {
                        if simulated == nil {
                            let payload = QRPayload.animated(text: String(repeating: DisplayDemo.sampleToken, count: 4), maxFragmentLength: 150)
                            let source = try! ScriptedCodeSource(payload: payload, interval: .milliseconds(120))
                            let s = QRScanner(configuration: .init(rescanInterval: .zero), source: source)
                            s.onResult = { result = $0 }
                            simulated = s
                        } else {
                            Task { await simulated?.stop() }
                            simulated = nil
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let camera = scanner.camera, camera.hasTorch {
                        Button { torch.toggle(); camera.setTorch(torch) } label: {
                            Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                    }
                    Button {
                        Task { try? await scanner.camera?.setPosition(scanner.camera?.position == .back ? .front : .back) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                    }
                }
            }
            .onAppear { scanner.onResult = { result = $0 } }
            .sheet(item: $result) { result in
                ResultSheet(result: result) {
                    self.result = nil
                    active.reset()
                }
            }
        }
    }

    @ViewBuilder
    private func overlay(for scanner: QRScanner) -> some View {
        VStack {
            Spacer()
            if let progress = scanner.progress {
                VStack(spacing: 8) {
                    FragmentBar(progress: progress, tint: .white)
                    Text("\(progress.receivedFragments) of \(progress.expectedFragments) fragments · \(progress.processedParts) parts seen · \(progress.pendingMixedParts) mixed pending")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
            HStack {
                ScanProgressRing(progress: scanner.progress, state: scanner.state) { scanner.reset() }
                Spacer()
                Text(label(for: scanner.state))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .padding()
        }
    }

    private func label(for state: QRScanner.State) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .unauthorized: return "unauthorized"
        case .unavailable: return "unavailable"
        case .scanning: return "scanning"
        case .completed: return "done"
        case .failed(let e): return "failed: \(e.localizedDescription)"
        }
    }
}

extension ScanResult: @retroactive Identifiable {
    public var id: String { string ?? "\(hashValue)" }
}

struct SimulatedScanOverlay: View {
    let scanner: QRScanner

    var body: some View {
        VStack(spacing: 16) {
            Text("Simulated scan of a 150-byte-fragment animated code")
                .foregroundStyle(.white)
            if let progress = scanner.progress {
                FragmentBar(progress: progress, tint: .white)
                    .padding(.horizontal)
                Text("\(Int((progress.fraction * 100).rounded())) %")
                    .font(.largeTitle.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ScanProgressRing(progress: scanner.progress, state: scanner.state) { scanner.reset() }
            Button("Reset") { scanner.reset() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct ResultSheet: View {
    let result: ScanResult
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch result {
                    case .text: Label("Plain code", systemImage: "textformat")
                    case .ur(let ur): Label("UR \(ur.type) · \(ur.cbor.count) bytes", systemImage: "square.stack.3d.down.forward")
                    }
                    Text(result.string ?? "(binary)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("Scanned")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Scan again", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
