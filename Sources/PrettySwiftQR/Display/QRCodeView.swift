//
//  QRCodeView.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// Displays a static or animated QR code.
///
/// ```swift
/// QRCodeView(.auto(token))
///     .qrStyle(.rounded(0.45))
///     .qrColors(foreground: .black, background: .white)
///     .qrFrameRate(8)
/// ```
///
/// The view keeps a stable identity while an animated code plays; only a
/// change of payload (or insertion/removal of the view) runs the reveal effect.
///
/// Payload swaps are choreographed by the view itself: the previous symbol
/// dissolves while the new one appears, both driven by an animatable reveal.
/// Appearing works the same way (the symbol starts hidden and appears once on
/// screen); only removal relies on `.transition(.qrReveal)`.
///
/// With the default liquid reveal the code can also flow into a shape and
/// back with `.qrMorph(_:)`, for example a checkmark once a payment arrives.
public struct QRCodeView<Placeholder: View>: View {
    private let payload: QRPayload
    private let placeholder: (Error?) -> Placeholder
    private let externalDriver: QRFrameDriver?

    @Environment(\.qrStyle) private var style
    @Environment(\.qrFrameRate) private var frameRate
    @Environment(\.qrRevealStyle) private var revealStyle
    @Environment(\.qrMorph) private var morphRequest
    @Environment(\.scenePhase) private var scenePhase
    @State private var internalDriver = QRFrameDriver()
    @State private var isActive = true
    /// The current symbol plus any previous ones still dissolving.
    @State private var symbols: [SymbolEntry] = []
    /// 0 the code, 1 `morphTarget`. The target stays set until the code is back.
    @State private var morph: Double = 0
    @State private var morphTarget: QRMorphTarget?
    @State private var morphGeneration = 0
    @State private var lastTaskKey: TaskKey?

    private var driver: QRFrameDriver { externalDriver ?? internalDriver }

    private var swapAnimation: Animation {
        revealStyle.isEnabled ? revealStyle.animation : .easeInOut(duration: 0.25)
    }

    /// - Parameters:
    ///   - payload: what to encode.
    ///   - driver: supply your own to observe the frame sequence (fragment bars, debug overlays).
    ///   - placeholder: shown while encoding and when encoding fails (the error is passed).
    public init(_ payload: QRPayload, driver: QRFrameDriver? = nil, @ViewBuilder placeholder: @escaping (Error?) -> Placeholder) {
        self.payload = payload
        self.externalDriver = driver
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            ForEach(symbols) { entry in
                if let matrix = matrix(for: entry) {
                    let outgoing = entry.generation != driver.swapGeneration
                    RevealedSymbol(matrix: matrix, style: style, revealStyle: outgoing ? revealStyle.displacing : revealStyle, reveal: entry.reveal,
                                   morph: morph, morphTarget: morphTarget)
                        .onAppear {
                            if entry.reveal < 1 { reveal(entry.generation) }
                        }
                }
            }
            if driver.matrix == nil {
                placeholder(driver.error)
                    .transition(.opacity)
            }
        }
        .background(style.background)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .transition(revealStyle.isEnabled ? AnyTransition.qrReveal : .opacity)
        .onChange(of: driver.swapGeneration, initial: true) { _, generation in
            symbolsDidSwap(to: generation)
        }
        .onChange(of: morphRequest.target, initial: true) { old, target in
            morph(to: target, animated: old != target)
        }
        .task(id: taskKey) {
            let key = taskKey
            if revealStyle.liquid != nil {
                // Compile the liquid shader before the first symbol appears.
                await QRLiquidGPU.prepare()
                guard !Task.isCancelled else { return }
            }
            // Back from a morph: play on from the frame that was held.
            let resuming = lastTaskKey.map { $0.morphed && !key.morphed && $0.loading == key.loading } ?? false
            lastTaskKey = key
            if key.morphed, driver.loadedPayload == payload, driver.matrix != nil {
                return // morphed: hold the frame on screen
            }
            if !resuming {
                let swapped = await driver.load(payload, errorCorrection: style.errorCorrection)
                guard isActive, !Task.isCancelled else { return }
                if swapped, revealStyle.isEnabled {
                    // Let the first frame finish revealing before frames start cycling.
                    try? await Task.sleep(for: .seconds(revealStyle.duration))
                    guard !Task.isCancelled else { return }
                }
            }
            guard !key.morphed else { return }
            await driver.play(framesPerSecond: frameRate)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            isActive = phase != .background
        }
    }

    private var accessibilityText: String {
        if driver.matrix == nil {
            return driver.error == nil ? "Preparing QR code" : "QR code unavailable"
        }
        return driver.isAnimated ? "Animated QR code, part \(driver.sequenceNumber) of a \(driver.fragmentCount)-fragment message" : "QR code"
    }

    private var taskKey: TaskKey {
        TaskKey(loading: LoadingKey(payload: payload, errorCorrection: style.errorCorrection, frameRate: frameRate, active: isActive),
                morphed: morphTarget != nil)
    }

    private struct LoadingKey: Equatable {
        let payload: QRPayload
        let errorCorrection: QRErrorCorrection?
        let frameRate: Double
        let active: Bool
    }

    private struct TaskKey: Equatable {
        let loading: LoadingKey
        /// Frames hold while the code is morphed into a shape.
        let morphed: Bool
    }

    // MARK: Morph

    private func morph(to target: QRMorphTarget?, animated: Bool) {
        morphGeneration += 1
        let generation = morphGeneration
        guard revealStyle.liquid != nil, revealStyle.isEnabled else {
            morphTarget = nil
            morph = 0
            return
        }
        guard animated else {
            // Already morphed when the view appears: start as the shape.
            morphTarget = target
            morph = target == nil ? 0 : 1
            return
        }
        let animation = Animation.linear(duration: morphRequest.duration)
        guard let target else {
            withAnimation(animation) { morph = 0 } completion: {
                if generation == morphGeneration { morphTarget = nil }
            }
            return
        }
        if let current = morphTarget, current != target, morph > 0 {
            // Another shape: flow back into the code first, then into the new shape.
            withAnimation(animation) { morph = 0 } completion: {
                guard generation == morphGeneration else { return }
                morphTarget = target
                withAnimation(animation) { morph = 1 }
            }
            return
        }
        morphTarget = target
        withAnimation(animation) { morph = 1 }
    }

    // MARK: Swap choreography

    private struct SymbolEntry: Identifiable {
        let generation: Int
        /// Last frame of a payload that is no longer current; nil for the current symbol.
        var frozen: QRMatrix?
        var reveal: Double
        var id: Int { generation }
    }

    /// The current symbol follows the driver's frames; dissolving ones keep their last frame.
    private func matrix(for entry: SymbolEntry) -> QRMatrix? {
        entry.generation == driver.swapGeneration ? driver.matrix : (entry.frozen ?? driver.previousMatrix)
    }

    private func symbolsDidSwap(to generation: Int) {
        guard generation > 0 else { return } // nothing loaded yet

        for index in symbols.indices where symbols[index].generation != generation && symbols[index].frozen == nil {
            symbols[index].frozen = driver.previousMatrix
        }
        guard driver.matrix != nil else {
            // Encoding failed: dissolve what is on screen, the placeholder shows the error.
            dissolve(allExcept: nil)
            return
        }
        guard !symbols.contains(where: { $0.generation == generation }) else { return }

        // Every symbol starts hidden and grows once it is on screen (`reveal(_:)`
        // runs from its `onAppear`), including one that is already loaded when
        // this view is inserted. The view's `.transition(.qrReveal)` cannot do
        // that: the symbol is added a transaction after the transition moved the
        // environment to its identity value, so the shape would have nothing to
        // interpolate and simply pop in (observed on iOS 26).
        symbols.append(SymbolEntry(generation: generation, frozen: nil, reveal: 0))
    }

    private func reveal(_ generation: Int) {
        dissolve(allExcept: generation)
    }

    /// Grows `generation` to full and dissolves every other symbol, then drops them.
    private func dissolve(allExcept generation: Int?) {
        withAnimation(swapAnimation) {
            for index in symbols.indices {
                symbols[index].reveal = symbols[index].generation == generation ? 1 : 0
            }
        } completion: {
            symbols.removeAll { $0.generation != generation && $0.reveal == 0 }
        }
    }
}

public extension QRCodeView where Placeholder == QRCodePlaceholder {
    init(_ payload: QRPayload, driver: QRFrameDriver? = nil) {
        self.init(payload, driver: driver) { error in QRCodePlaceholder(error: error) }
    }

    /// A static code for `text`. Use `init(auto:)` for strings that may be long.
    init(text: String) {
        self.init(.text(text))
    }

    /// Static up to 600 bytes, animated above (see `QRPayload.auto`).
    init(auto text: String, staticLimit: Int = QRPayload.defaultStaticLimit, maxFragmentLength: Int = QRPayload.defaultMaxFragmentLength) {
        self.init(.auto(text, staticLimit: staticLimit, maxFragmentLength: maxFragmentLength))
    }

    /// An animated (fountain-coded) `ur:bytes` code.
    init(animated data: Data, maxFragmentLength: Int = QRPayload.defaultMaxFragmentLength) {
        self.init(.animated(data, maxFragmentLength: maxFragmentLength))
    }
}

/// One symbol. Combines the reveal driven by `QRCodeView`'s swap choreography
/// with `qrReveal` from an enclosing `.transition(.qrReveal)`. Reads the
/// environment *here*, beneath the transition, so the symbol interpolates.
private struct RevealedSymbol: View {
    let matrix: QRMatrix
    let style: QRStyle
    let revealStyle: QRReveal
    let reveal: Double
    let morph: Double
    let morphTarget: QRMorphTarget?

    @Environment(\.qrReveal) private var transitionReveal

    var body: some View {
        let shown = min(transitionReveal, revealStyle.isEnabled ? reveal : 1)
        if revealStyle.isEnabled, let liquid = revealStyle.liquid, QRLiquidGPU.ready != nil {
            QRLiquidSymbol(matrix: matrix, style: style, liquid: liquid, target: morphTarget,
                           reveal: shown, morph: morphTarget == nil ? 0 : morph)
        } else {
            QRCodeShape(matrix: matrix, radii: style.radii, quietZone: style.quietZone, reveal: shown, revealStyle: revealStyle)
                .fill(style.foreground)
                // With reveals disabled the swap is a plain cross-fade.
                .opacity(revealStyle.isEnabled ? 1 : reveal)
        }
    }
}

/// Default placeholder: a faint symbol while encoding, a warning when it fails.
public struct QRCodePlaceholder: View {
    public let error: Error?

    public init(error: Error?) { self.error = error }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.2))
                        Text(error.localizedDescription)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                } else {
                    Image(systemName: "qrcode")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.quaternary)
                        .padding(proxy.size.width * 0.2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityLabel(error == nil ? "Preparing QR code" : "QR code unavailable")
    }
}

#if DEBUG
#Preview("Static") {
    VStack(spacing: 24) {
        QRCodeView(text: "https://example.com")
            .frame(width: 180)
        QRCodeView(text: "https://example.com")
            .qrStyle(.square)
            .frame(width: 180)
        QRCodeView(text: "https://example.com")
            .qrCornerRadius(0.3, inner: 0)
            .qrColors(foreground: .indigo, background: .white)
            .frame(width: 180)
    }
    .padding()
}

#Preview("Animated") {
    QRCodeView(auto: String(repeating: "cashuAeyJ0b2tlbiI6W3sicHJvb2ZzIjpb", count: 40))
        .qrColors(foreground: .black, background: .white)
        .padding()
}
#endif
