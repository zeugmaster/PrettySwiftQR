//
//  QRLiquidView.swift
//  PrettySwiftQR
//
//  The liquid transitions on screen. `QRLiquidSymbol` is animatable: SwiftUI
//  interpolates its reveal and morph progress, and for every frame in between
//  it draws the liquid with Metal; at rest it is the vector `QRCodeShape`, the
//  same outline as without any transition.
//

import SwiftUI
import QuartzCore
import PrettyQRCore

/// A symbol that appears, disappears and morphs as liquid.
///
/// - `reveal`: 0 hidden, 1 shown. In between the code is pulled apart (or
///   gathers, when growing).
/// - `morph`: 0 the code, 1 `target`.
nonisolated struct QRLiquidSymbol: View, Animatable {
    let matrix: QRMatrix
    let style: QRStyle
    let liquid: QRLiquidStyle
    let target: QRMorphTarget?
    var reveal: Double
    var morph: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(reveal, morph) }
        set { reveal = newValue.first; morph = newValue.second }
    }

    var body: some View {
        if let target, morph > 0 {
            QRLiquidCanvas(request: request(motion: .flow(target), progress: morph))
                // A morphed code that is removed or replaced fades out as a whole.
                .opacity(min(max(reveal, 0), 1))
        } else if reveal <= 0 {
            // Hidden, but still a view: `QRCodeView` starts the reveal from its `onAppear`.
            Color.clear
        } else if reveal < 1 {
            QRLiquidCanvas(request: request(motion: .pullApart, progress: 1 - reveal))
        } else {
            QRCodeShape(matrix: matrix, radii: style.radii, quietZone: style.quietZone)
                .fill(style.foreground)
        }
    }

    private func request(motion: QRLiquidMotion, progress: Double) -> QRLiquidCanvas.Request {
        QRLiquidCanvas.Request(matrix: matrix, radii: style.radii, quietZone: style.quietZone, liquid: liquid,
                               motion: motion, progress: min(max(progress, 0), 1), foreground: style.foreground)
    }
}

/// Hosts the Metal layer. Colours are resolved against the environment here.
struct QRLiquidCanvas {
    struct Request: Equatable {
        var matrix: QRMatrix
        var radii: QROutlineRadii
        var quietZone: Double
        var liquid: QRLiquidStyle
        var motion: QRLiquidMotion
        var progress: Double
        var foreground: Color

        func resolved(in environment: EnvironmentValues) -> QRLiquidRequest {
            let c = foreground.resolve(in: environment)
            let a = Float(c.opacity)
            return QRLiquidRequest(matrix: matrix, radii: radii, quietZone: quietZone, liquid: liquid, motion: motion,
                                   progress: progress, foreground: SIMD4(c.red * a, c.green * a, c.blue * a, a))
        }
    }

    let request: Request
}

#if canImport(UIKit)
import UIKit

extension QRLiquidCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> QRLiquidLayerView {
        QRLiquidLayerView()
    }

    func updateUIView(_ view: QRLiquidLayerView, context: Context) {
        view.request = request.resolved(in: context.environment)
    }
}

/// A view backed by a `CAMetalLayer` that draws whenever its request or size changes.
final class QRLiquidLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var renderer: QRLiquidRenderer?
    var request: QRLiquidRequest? {
        didSet { if request != oldValue { render() } }
    }

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        if let gpu = QRLiquidGPU.ready {
            renderer = QRLiquidRenderer(gpu: gpu)
            let layer = self.layer as! CAMetalLayer
            layer.device = gpu.device
            layer.pixelFormat = QRLiquidGPU.pixelFormat
            layer.framebufferOnly = true
            layer.isOpaque = false
            layer.presentsWithTransaction = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: QRLiquidLayerView, _: UITraitCollection) in view.render() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        render()
    }

    private func render() {
        guard let renderer, let request, bounds.width > 0, bounds.height > 0 else { return }
        let layer = self.layer as! CAMetalLayer
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        layer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        renderer.render(request, to: drawable)
    }
}

#elseif canImport(AppKit)
import AppKit

extension QRLiquidCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> QRLiquidLayerView {
        QRLiquidLayerView()
    }

    func updateNSView(_ view: QRLiquidLayerView, context: Context) {
        view.request = request.resolved(in: context.environment)
    }
}

/// A view backed by a `CAMetalLayer` that draws whenever its request or size changes.
final class QRLiquidLayerView: NSView {
    private var renderer: QRLiquidRenderer?
    private let metalLayer = CAMetalLayer()
    var request: QRLiquidRequest? {
        didSet { if request != oldValue { render() } }
    }

    init() {
        super.init(frame: .zero)
        if let gpu = QRLiquidGPU.ready {
            renderer = QRLiquidRenderer(gpu: gpu)
            metalLayer.device = gpu.device
            metalLayer.pixelFormat = QRLiquidGPU.pixelFormat
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = false
            metalLayer.presentsWithTransaction = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    private func render() {
        guard let renderer, let request, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(request, to: drawable)
    }
}
#endif
