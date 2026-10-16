//
//  QRReveal.swift
//  PrettySwiftQR
//
//  The appear/disappear effect: every module grows from its centre into its
//  final rounded form, staggered across the symbol so the code looks like it
//  condenses out of liquid. Driven by a single scalar (`reveal`, 0…1) that a
//  SwiftUI transition animates; frames of an animated code never touch it.
//

import SwiftUI
import PrettyQRCore

/// How modules are staggered during a reveal.
public struct QRReveal: Hashable, Sendable {
    public enum Order: Hashable, Sendable {
        /// Every module at once.
        case simultaneous
        /// Ripple outward from the symbol centre (inward on disappear).
        case fromCenter
        /// Diagonal sweep from the top-left finder.
        case fromTopLeft
        /// Row by row from the top.
        case fromTop
        /// Pseudo-random order, stable for a given seed.
        case random(seed: UInt64)
    }

    public var order: Order
    /// Share of the reveal spent staggering: 0 means all modules animate
    /// together, 0.7 means the last module starts when the first is 70 % done.
    public var stagger: Double
    /// Scale overshoot at the end of each module's growth (0 = none).
    public var overshoot: Double
    public var duration: Double
    /// When false, `QRCodeView` applies no transition of its own.
    public var isEnabled: Bool
    /// Runs the stagger the other way round (last modules first). Used for a
    /// symbol that is being replaced, so the incoming one displaces it as a
    /// wave instead of both overlapping where the incoming one starts.
    var reversesStagger = false

    public init(order: Order = .fromCenter, stagger: Double = 0.55, overshoot: Double = 0.12, duration: Double = 0.7, isEnabled: Bool = true) {
        self.order = order
        self.stagger = min(max(stagger, 0), 0.95)
        self.overshoot = min(max(overshoot, 0), 1)
        self.duration = max(0.05, duration)
        self.isEnabled = isEnabled
    }

    public static let liquid = QRReveal()
    public static let none = QRReveal(isEnabled: false)

    /// The same reveal with the stagger reversed, for the outgoing symbol of a swap.
    var displacing: QRReveal {
        var copy = self
        copy.reversesStagger.toggle()
        return copy
    }

    public var animation: Animation {
        .easeInOut(duration: duration)
    }

    // MARK: Timing

    /// Normalised start time (0…stagger) for a point in module coordinates.
    func delay(for point: QRPoint, size: Int) -> Double {
        guard stagger > 0, size > 0 else { return 0 }
        let n = Double(size)
        let t: Double
        switch order {
        case .simultaneous:
            t = 0
        case .fromCenter:
            let dx = point.x - n / 2, dy = point.y - n / 2
            t = (dx * dx + dy * dy).squareRoot() / (n / 2 * 2.0.squareRoot())
        case .fromTopLeft:
            t = (point.x + point.y) / (2 * n)
        case .fromTop:
            t = point.y / n
        case .random(let seed):
            var h = seed ^ 0x9E3779B97F4A7C15
            h ^= UInt64(bitPattern: Int64(point.x * 2)) &* 0xBF58476D1CE4E5B9
            h ^= UInt64(bitPattern: Int64(point.y * 2)) &* 0x94D049BB133111EB
            h ^= h >> 31
            h = h &* 0xBF58476D1CE4E5B9
            h ^= h >> 29
            t = Double(h % 10_000) / 10_000
        }
        let clamped = min(max(t, 0), 1)
        return (reversesStagger ? 1 - clamped : clamped) * stagger
    }

    /// Scale (0…1+overshoot) of a module at `reveal` given its `delay`.
    func scale(reveal: Double, delay: Double) -> Double {
        let span = max(1e-6, 1 - stagger)
        let s = min(max((reveal - delay) / span, 0), 1)
        if s <= 0 { return 0 }
        if s >= 1 { return 1 }
        // ease-out-back: overshoots past 1 then settles.
        let c1 = 1.70158 * overshoot * 2
        let c3 = c1 + 1
        let u = s - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
}

// MARK: Environment plumbing

private struct QRRevealKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct QRRevealStyleKey: EnvironmentKey {
    static let defaultValue = QRReveal.liquid
}

public extension EnvironmentValues {
    /// 0 = fully hidden, 1 = fully drawn. Animated by `QRRevealTransition`.
    ///
    /// Read this *below* the view that carries the transition: a modifier can
    /// only change the environment of its content, never of its ancestors.
    var qrReveal: Double {
        get { self[QRRevealKey.self] }
        set { self[QRRevealKey.self] = min(max(newValue, 0), 1) }
    }

    var qrRevealStyle: QRReveal {
        get { self[QRRevealStyleKey.self] }
        set { self[QRRevealStyleKey.self] = newValue }
    }
}

public extension View {
    /// Configures the appear/disappear effect of `QRCodeView`s in this hierarchy.
    func qrReveal(_ reveal: QRReveal) -> some View {
        environment(\.qrRevealStyle, reveal)
    }
}

/// Animatable modifier that feeds `reveal` to every `QRCodeShape` below it.
///
/// Apply it, or `.transition(.qrReveal)`, to a *container* (a `ZStack` is
/// enough) that holds the view reading `qrReveal`, never to that view itself.
/// SwiftUI treats an environment change made by a transition modifier as a
/// plain jump when the modified view is the reader, so nothing animates; with
/// a container in between the reader's shape interpolates as expected.
/// Wrapping `content` in a `ZStack` inside this body does not help. Use it
/// for inserting and removing a view; for swapping payloads in place,
/// `QRCodeView` animates the shape's reveal directly instead of relying on
/// `.id` transitions, which proved unreliable (iOS 18 simulator, Xcode 26.6).
public nonisolated struct QRRevealModifier: ViewModifier, Animatable {
    public var reveal: Double

    public init(reveal: Double) { self.reveal = reveal }

    public var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    public func body(content: Content) -> some View {
        // Nested reveals combine. While a parent dissolves (1 → 0) a child at its
        // identity value (1) must not override it, so take the minimum.
        content.transformEnvironment(\.qrReveal) { $0 = min($0, reveal) }
    }
}

/// The liquid reveal as a SwiftUI transition.
public struct QRRevealTransition: Transition {
    public init() {}

    public func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(QRRevealModifier(reveal: phase.isIdentity ? 1 : 0))
    }
}

public extension Transition where Self == QRRevealTransition {
    /// Modules grow from their centres on insertion and shrink on removal.
    static var qrReveal: QRRevealTransition { QRRevealTransition() }
}

public extension AnyTransition {
    static var qrReveal: AnyTransition {
        .modifier(active: QRRevealModifier(reveal: 0), identity: QRRevealModifier(reveal: 1))
    }
}
