//
//  QRLiquidStyle.swift
//  PrettySwiftQR
//
//  Parameters of the liquid transitions and the shapes a code can flow into.
//

import SwiftUI
import PrettyQRCore

/// How the liquid transitions behave.
///
/// The code behaves like mercury: to disappear it melts into drops that are
/// pulled apart toward invisible magnets, merge with whatever arrived there and
/// sink; to appear the same film runs backwards. Neighbouring drops stay joined
/// by threads that stretch, snap and recoil. At rest the code is always the
/// exact styled symbol, so legibility never depends on these settings.
///
/// ```swift
/// QRCodeView(payload)
///     .qrReveal(.liquid(QRLiquidStyle(tension: 0.3, stagger: 0.6, dropsPerSide: 8)))
/// ```
public struct QRLiquidStyle: Hashable, Sendable {
    /// How far apart two bodies of liquid still join through a neck, in modules (0…0.6).
    public var tension: Double
    /// How far the drops' timing is spread (0.1…0.9): low values move every drop
    /// together, high values let them start and finish one after another.
    public var stagger: Double
    /// How many drops the code is cut into along each side (4…12).
    public var dropsPerSide: Int

    public init(tension: Double = 0.26, stagger: Double = 0.55, dropsPerSide: Int = 7) {
        self.tension = min(max(tension, 0), 0.6)
        self.stagger = min(max(stagger, 0.1), 0.9)
        self.dropsPerSide = min(max(dropsPerSide, 4), 12)
    }

    public static let `default` = QRLiquidStyle()
}

/// A shape a code can flow into, built from the code's own liquid: a stroke of
/// constant width along a polyline.
///
/// Drops land along the stroke in proportion to their mass, so the shape is
/// only complete once the last drop has arrived.
public struct QRMorphTarget: Hashable, Sendable {
    /// Centre line of the stroke in unit coordinates of the symbol: (0, 0) is the
    /// top-left module corner, (1, 1) the bottom-right; the quiet zone is outside.
    /// Two to eight points.
    public let points: [QRPoint]
    /// Stroke width as a fraction of the symbol's side.
    public let lineWidth: Double

    public init(points: [QRPoint], lineWidth: Double) {
        precondition(points.count >= 2, "a stroke needs at least two points")
        self.points = Array(points.prefix(Self.maximumPointCount))
        self.lineWidth = min(max(lineWidth, 0.02), 0.5)
    }

    static let maximumPointCount = 8

    /// A tick, for "paid", "sent" or "scanned".
    public static let checkmark = QRMorphTarget(points: [QRPoint(0.25, 0.53), QRPoint(0.43, 0.71), QRPoint(0.76, 0.31)], lineWidth: 0.156)
}

/// The morph requested for `QRCodeView`s in a hierarchy.
struct QRMorph: Hashable, Sendable {
    var target: QRMorphTarget?
    var duration: Double
}

private struct QRMorphKey: EnvironmentKey {
    static let defaultValue = QRMorph(target: nil, duration: 1.6)
}

extension EnvironmentValues {
    var qrMorph: QRMorph {
        get { self[QRMorphKey.self] }
        set { self[QRMorphKey.self] = newValue }
    }
}

public extension View {
    /// Flows every `QRCodeView` below into `target`, or back into the code when
    /// `target` is nil. The flow is part of the liquid transitions (see
    /// `QRReveal.liquid`); with other reveals, or where Metal is unavailable, the
    /// code stays as it is. An animated code holds its current frame while it is
    /// morphed and starts again from its first frame once it is back.
    ///
    /// ```swift
    /// QRCodeView(.text(invoice))
    ///     .qrMorph(isPaid ? .checkmark : nil)
    /// ```
    func qrMorph(_ target: QRMorphTarget?, duration: Double = 1.6) -> some View {
        environment(\.qrMorph, QRMorph(target: target, duration: max(0.05, duration)))
    }
}
