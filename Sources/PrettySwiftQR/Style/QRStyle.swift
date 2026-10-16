//
//  QRStyle.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// Colours, corner rounding and layout of a rendered QR code.
public struct QRStyle: Hashable, Sendable {
    public var foreground: Color
    public var background: Color
    /// Corner radii in module units. See `QROutlineRadii`.
    public var radii: QROutlineRadii
    /// Light margin around the symbol, in modules. The QR spec asks for 4; 2 scans fine on phones.
    public var quietZone: Double
    /// nil picks `.low` for animated and `.medium` for static payloads.
    public var errorCorrection: QRErrorCorrection?

    public init(foreground: Color = .primary, background: Color = .clear, radii: QROutlineRadii = .round, quietZone: Double = 2, errorCorrection: QRErrorCorrection? = nil) {
        self.foreground = foreground
        self.background = background
        self.radii = radii
        self.quietZone = max(0, quietZone)
        self.errorCorrection = errorCorrection
    }

    public static let `default` = QRStyle()
    public static let square = QRStyle(radii: .square)

    /// Rounded modules with finder radii derived from the module radius.
    public static func rounded(_ module: Double = 0.5, inner: Double? = nil) -> QRStyle {
        QRStyle(radii: .derived(module: module, inner: inner))
    }

    public func foreground(_ color: Color) -> QRStyle { var s = self; s.foreground = color; return s }
    public func background(_ color: Color) -> QRStyle { var s = self; s.background = color; return s }
    public func radii(_ radii: QROutlineRadii) -> QRStyle { var s = self; s.radii = radii; return s }
    public func quietZone(_ modules: Double) -> QRStyle { var s = self; s.quietZone = max(0, modules); return s }
    public func errorCorrection(_ level: QRErrorCorrection?) -> QRStyle { var s = self; s.errorCorrection = level; return s }
}

private struct QRStyleKey: EnvironmentKey {
    static let defaultValue = QRStyle.default
}

private struct QRFrameRateKey: EnvironmentKey {
    static let defaultValue: Double = 10
}

public extension EnvironmentValues {
    var qrStyle: QRStyle {
        get { self[QRStyleKey.self] }
        set { self[QRStyleKey.self] = newValue }
    }

    /// Frames per second for animated codes.
    var qrFrameRate: Double {
        get { self[QRFrameRateKey.self] }
        set { self[QRFrameRateKey.self] = max(0.5, newValue) }
    }
}

public extension View {
    /// Sets the style for all `QRCodeView`s in this hierarchy.
    func qrStyle(_ style: QRStyle) -> some View {
        environment(\.qrStyle, style)
    }

    /// Adjusts the inherited style.
    func qrStyle(_ transform: @escaping (QRStyle) -> QRStyle) -> some View {
        transformEnvironment(\.qrStyle) { $0 = transform($0) }
    }

    func qrColors(foreground: Color, background: Color = .clear) -> some View {
        qrStyle { $0.foreground(foreground).background(background) }
    }

    /// Module corner radius in module units (0 square … 0.5 fully round), finder radii derived.
    func qrCornerRadius(_ module: Double, inner: Double? = nil) -> some View {
        qrStyle { $0.radii(.derived(module: module, inner: inner)) }
    }

    func qrRadii(_ radii: QROutlineRadii) -> some View {
        qrStyle { $0.radii(radii) }
    }

    func qrQuietZone(_ modules: Double) -> some View {
        qrStyle { $0.quietZone(modules) }
    }

    /// Frames per second for animated codes (default 10).
    func qrFrameRate(_ framesPerSecond: Double) -> some View {
        environment(\.qrFrameRate, framesPerSecond)
    }
}
