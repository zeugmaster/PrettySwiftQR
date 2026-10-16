import SwiftUI
import PrettySwiftQR

/// Shows a code for any text with live style controls, and exercises the
/// appear/disappear transition and payload switching.
struct DisplayDemo: View {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, `static`, animated
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case center, topLeft, top, random, none
        var id: String { rawValue }
        var reveal: QRReveal {
            switch self {
            case .center: return QRReveal(order: .fromCenter)
            case .topLeft: return QRReveal(order: .fromTopLeft)
            case .top: return QRReveal(order: .fromTop)
            case .random: return QRReveal(order: .random(seed: 1))
            case .none: return .none
            }
        }
    }

    @State private var text = DisplayDemo.sampleToken
    @State private var mode: Mode = .auto
    @State private var isShown = true
    @State private var moduleRadius = 0.5
    @State private var innerRadius = 0.5
    @State private var finderRadius = 1.5
    @State private var quietZone = 2.0
    @State private var foreground = Color.black
    @State private var background = Color.white
    @State private var frameRate = 10.0
    @State private var maxFragment = 200.0
    @State private var order: Order = .center
    @State private var driver = QRFrameDriver()
    @State private var exportImage: Image?

    private var payload: QRPayload {
        switch mode {
        case .auto: return .auto(text, maxFragmentLength: Int(maxFragment))
        case .static: return .text(text)
        case .animated: return .animated(text: text, maxFragmentLength: Int(maxFragment))
        }
    }

    private var style: QRStyle {
        QRStyle(foreground: foreground, background: background,
                radii: QROutlineRadii(module: moduleRadius, inner: innerRadius, finderOuter: finderRadius, finderInner: finderRadius * 0.7, finderCenter: finderRadius * 0.5),
                quietZone: quietZone)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        if isShown {
                            QRCodeView(payload, driver: driver)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .qrStyle(style)
                    .qrFrameRate(frameRate)
                    .qrReveal(order.reveal)
                    .animation(order.reveal.animation, value: isShown)
                    .listRowBackground(background)

                    if driver.isAnimated {
                        FragmentBar(fragmentCount: driver.fragmentCount, current: driver.fragmentIndexes, tint: .accentColor)
                        LabeledContent("Frame", value: "\(driver.sequenceNumber) · \(driver.fragmentCount) fragments · version \(driver.version)")
                            .font(.footnote.monospacedDigit())
                    } else if driver.matrix != nil {
                        LabeledContent("Symbol", value: "static · version \(driver.version)")
                            .font(.footnote)
                    }
                    Toggle("Show code", isOn: $isShown)
                }

                Section("Payload") {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(height: 90)
                    HStack {
                        Button("Short") { text = "https://example.com/pay?amount=21" }
                        Spacer()
                        Button("Token") { text = DisplayDemo.sampleToken }
                        Spacer()
                        Button("Huge") { text = String(repeating: DisplayDemo.sampleToken, count: 6) }
                    }
                    .buttonStyle(.bordered)
                    LabeledContent("Bytes", value: "\(text.utf8.count)")
                }

                Section("Style") {
                    slider("Module radius", value: $moduleRadius, range: 0...0.5)
                    slider("Inner radius", value: $innerRadius, range: 0...0.5)
                    slider("Finder radius", value: $finderRadius, range: 0...3.5)
                    slider("Quiet zone", value: $quietZone, range: 0...4)
                    ColorPicker("Foreground", selection: $foreground)
                    ColorPicker("Background", selection: $background)
                }

                Section("Animation") {
                    Picker("Reveal", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                    slider("Frames per second", value: $frameRate, range: 2...30)
                    slider("Max fragment bytes", value: $maxFragment, range: 50...600)
                }

                Section("Export") {
                    if let exportImage {
                        ShareLink(item: exportImage, preview: SharePreview("QR code", image: exportImage)) {
                            Label("Share PNG", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Render PNG") {
                        exportImage = try? QRCodeImageRenderer.image(for: .text(text), style: style, pixelSize: 1024)
                    }
                    .disabled(payload.isUR && (try? QRFrameEncoder(payload: payload))?.isAnimated == true)
                }
            }
            .navigationTitle("PrettySwiftQR")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: "%.2f", value.wrappedValue))
            Slider(value: value, in: range)
        }
    }

    static let sampleToken = "cashuBo2FteBtodHRwczovL21pbnQubWFjYWRhbWlhLmNhc2hhdWNzYXRhdIGiYWlIAKjNnGW0Pj9hcIKjYWEBYXN4QDhlODgwYTA2OTZkOWU0N2IyYmQyMzM5YzBlYjQwZjQ0MWQxYjlhZjRkODNjOWE0NjgxM2U0ZmJlZTAzYzBiOTNhY1ghAgYpOhx8csuCIhQhCOAFxH7CouYSwoPiJkVZd38h6L/Yo2FhBGFzeEAyYjQxNjk1NTE3NTMzZDlkNDAxYWVkZDYyZmViNDljYzE4NDA2Njc2NTgwZDliNWI5MTJkMjA3Y2RhM2ZlNDhiYWNYIQPPWZ0YSQAa12b+/0apeu6KCENysbbpqCjrH+PS8melwg=="
}
