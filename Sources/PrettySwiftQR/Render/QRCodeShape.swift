//
//  QRCodeShape.swift
//  PrettySwiftQR
//

import SwiftUI
import os
import PrettyQRCore

/// A QR symbol as a SwiftUI `Shape`. Fill it with the default (nonzero)
/// rule: contours are oriented so finder eyes stay holes, and modules that
/// overlap while a reveal overshoots simply union.
///
/// Only `reveal` is animatable. The matrix is not, so swapping frames of an
/// animated code never interpolates, whatever animation is in flight.
public struct QRCodeShape: Shape {
    public var matrix: QRMatrix
    public var radii: QROutlineRadii
    public var quietZone: Double
    public var reveal: Double
    public var revealStyle: QRReveal

    public init(matrix: QRMatrix, radii: QROutlineRadii = .round, quietZone: Double = 2, reveal: Double = 1, revealStyle: QRReveal = .liquid) {
        self.matrix = matrix
        self.radii = radii
        self.quietZone = max(0, quietZone)
        self.reveal = min(max(reveal, 0), 1)
        self.revealStyle = revealStyle
    }

    public var animatableData: Double {
        get { reveal }
        set { reveal = min(max(newValue, 0), 1) }
    }

    public func path(in rect: CGRect) -> Path {
        let extent = Double(matrix.size) + 2 * quietZone
        let side = min(rect.width, rect.height)
        let scale = side / extent
        let origin = CGPoint(x: rect.midX - side / 2 + quietZone * scale, y: rect.midY - side / 2 + quietZone * scale)
        let commands = reveal >= 1 ? QRPathCache.shared.merged(matrix: matrix, radii: radii) : revealCommands()
        return Path(qrCommands: commands, scale: scale, origin: origin)
    }

    // MARK: Reveal decomposition

    private func revealCommands() -> [QRPathCommand] {
        guard reveal > 0 else { return [] }
        let size = matrix.size
        let decomposition = QRPathCache.shared.decomposition(matrix: matrix)
        var commands: [QRPathCommand] = []
        commands.reserveCapacity(decomposition.cells.count * 10)

        for cell in decomposition.cells {
            let s = revealStyle.scale(reveal: reveal, delay: revealStyle.delay(for: cell.center, size: size))
            guard s > 0 else { continue }
            commands += QROutline.cellPath(cell, radius: radii.module, scale: s)
        }

        if radii.inner > 0 {
            for fillet in decomposition.fillets {
                // Fillets join cells, so they appear during the last stretch of their neighbours' growth.
                let delay = revealStyle.delay(for: fillet.corner, size: size)
                let s = revealStyle.scale(reveal: reveal, delay: delay)
                guard s >= 0.85 else { continue }
                let t = min(1, (s - 0.85) / 0.15)
                commands += QROutline.filletPath(fillet, radius: radii.inner * t)
            }
        }

        for origin in matrix.finderOrigins {
            let center = QRPoint(Double(origin.x) + 3.5, Double(origin.y) + 3.5)
            let s = revealStyle.scale(reveal: reveal, delay: revealStyle.delay(for: center, size: size))
            guard s > 0 else { continue }
            commands += scaled(QROutline.finder(atX: Double(origin.x), y: Double(origin.y), radii: radii), about: center, by: s)
        }
        return commands
    }

    private func scaled(_ commands: [QRPathCommand], about c: QRPoint, by s: Double) -> [QRPathCommand] {
        func p(_ q: QRPoint) -> QRPoint { QRPoint(c.x + (q.x - c.x) * s, c.y + (q.y - c.y) * s) }
        return commands.map { command in
            switch command {
            case .move(let q): return .move(p(q))
            case .line(let q): return .line(p(q))
            case .corner(let corner, let end, let radius, let convex): return .corner(corner: p(corner), end: p(end), radius: radius * s, convex: convex)
            case .close: return .close
            }
        }
    }
}

public extension Path {
    /// Builds a path from module-space commands, scaling by `scale` and translating by `origin`.
    init(qrCommands commands: [QRPathCommand], scale: CGFloat = 1, origin: CGPoint = .zero) {
        self.init()
        func pt(_ p: QRPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        for command in commands {
            switch command {
            case .move(let p): move(to: pt(p))
            case .line(let p): addLine(to: pt(p))
            case .corner(let corner, let end, let radius, _):
                if radius > 0 {
                    addArc(tangent1End: pt(corner), tangent2End: pt(end), radius: radius * scale)
                } else {
                    addLine(to: pt(corner))
                }
                addLine(to: pt(end))
            case .close: closeSubpath()
            }
        }
    }
}

/// Memoises outlines so animated codes do not re-trace the same frames.
final class QRPathCache: Sendable {
    static let shared = QRPathCache()

    struct Decomposition: Sendable {
        let cells: [QRCell]
        let fillets: [QRFillet]
    }

    private struct MergedKey: Hashable { let matrix: Int; let radii: QROutlineRadii }

    private let merged = OSAllocatedUnfairLock<[MergedKey: [QRPathCommand]]>(initialState: [:])
    private let decompositions = OSAllocatedUnfairLock<[Int: Decomposition]>(initialState: [:])
    private let limit = 96

    func merged(matrix: QRMatrix, radii: QROutlineRadii) -> [QRPathCommand] {
        let key = MergedKey(matrix: matrix.hashValue, radii: radii)
        if let hit = merged.withLock({ $0[key] }) { return hit }
        let commands = QROutline.trace(matrix, radii: radii) + QROutline.finders(matrix, radii: radii)
        merged.withLock { cache in
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = commands
        }
        return commands
    }

    func decomposition(matrix: QRMatrix) -> Decomposition {
        let key = matrix.hashValue
        if let hit = decompositions.withLock({ $0[key] }) { return hit }
        let value = Decomposition(cells: QROutline.cells(matrix), fillets: QROutline.fillets(matrix))
        decompositions.withLock { cache in
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = value
        }
        return value
    }
}
