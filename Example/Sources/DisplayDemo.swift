import SwiftUI
import PrettySwiftQR

/// Shows a code for any text with live style controls, and exercises the
/// appear/disappear transition, the morph into a checkmark and payload switching.
///
/// Launch with `-liquidDemo` to loop appear, morph, morph back and disappear
/// on its own (for screen recordings).
struct DisplayDemo: View {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, `static`, animated
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case liquid, center, topLeft, top, random, none
        var id: String { rawValue }
        func reveal(_ liquid: QRLiquidStyle, duration: Double) -> QRReveal {
            switch self {
            case .liquid: return .liquid(liquid, duration: duration)
            case .center: return QRReveal(order: .fromCenter, duration: duration)
            case .topLeft: return QRReveal(order: .fromTopLeft, duration: duration)
            case .top: return QRReveal(order: .fromTop, duration: duration)
            case .random: return QRReveal(order: .random(seed: 1), duration: duration)
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
    @State private var order: Order = .liquid
    @State private var tension = QRLiquidStyle.default.tension
    @State private var stagger = QRLiquidStyle.default.stagger
    @State private var dropsPerSide = Double(QRLiquidStyle.default.dropsPerSide)
    @State private var isPaid = false
    /// Seconds for appearing, disappearing, payload swaps and the morph.
    @State private var duration = 0.6
    @State private var driver = QRFrameDriver()
    @State private var exportImage: Image?

    private var payload: QRPayload {
        switch mode {
        case .auto: return .auto(text, maxFragmentLength: Int(maxFragment))
        case .static: return .text(text)
        case .animated: return .animated(text: text, maxFragmentLength: Int(maxFragment))
        }
    }

    private var reveal: QRReveal {
        order.reveal(QRLiquidStyle(tension: tension, stagger: stagger, dropsPerSide: Int(dropsPerSide)), duration: duration)
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
                    .qrReveal(reveal)
                    .qrMorph(isPaid ? .checkmark : nil, duration: duration)
                    .animation(reveal.animation, value: isShown)
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
                    Toggle("Morph to ✓", isOn: $isPaid)
                        .disabled(order != .liquid)
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
                    slider("Duration (s)", value: $duration, range: 0.3...2)
                    if order == .liquid {
                        slider("Surface tension", value: $tension, range: 0...0.6)
                        slider("Stagger", value: $stagger, range: 0.1...0.9)
                        slider("Drops per side", value: $dropsPerSide, range: 4...12, step: 1)
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
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-liquidDemo") else { return }
                await runLiquidDemo()
            }
        }
    }

    /// Loops the liquid effects with pauses in between, for screen recordings:
    /// morph and back, disappear and appear, then the same with an animated code
    /// (whose frames hold while it is morphed) and payload swaps in between.
    private func runLiquidDemo() async {
        let invoice = "lightning:lnbc1u1pjexample0xyz9qrsgq7q8kz0f3n5y2w6a8d4c3v6b7n8m9"
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        mode = .static
        text = invoice
        while !Task.isCancelled {
            await pause(2); isPaid = true
            await pause(2.5); isPaid = false
            await pause(2.5); isShown = false
            await pause(2); isShown = true
            await pause(2.5); mode = .animated; text = DisplayDemo.sampleToken
            await pause(3); isPaid = true
            await pause(2.5); isPaid = false
            await pause(3); mode = .static; text = invoice
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: step == nil ? "%.2f" : "%.0f", value.wrappedValue))
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    static let sampleToken = "cashuBo2FteBtodHRwczovL21pbnQubWFjYWRhbWlhLmNhc2hhdWNzYXRhdIGiYWlIAKjNnGW0Pj9hcIKjYWEBYXN4QDhlODgwYTA2OTZkOWU0N2IyYmQyMzM5YzBlYjQwZjQ0MWQxYjlhZjRkODNjOWE0NjgxM2U0ZmJlZTAzYzBiOTNhY1ghAgYpOhx8csuCIhQhCOAFxH7CouYSwoPiJkVZd38h6L/Yo2FhBGFzeEAyYjQxNjk1NTE3NTMzZDlkNDAxYWVkZDYyZmViNDljYzE4NDA2Njc2NTgwZDliNWI5MTJkMjA3Y2RhM2ZlNDhiYWNYIQPPWZ0YSQAa12b+/0apeu6KCENysbbpqCjrH+PS8melwg=="
}
