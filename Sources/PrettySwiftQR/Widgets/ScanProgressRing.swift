//
//  ScanProgressRing.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// Circular progress for multi-part scans: hidden when idle, a ring while
/// collecting, a check mark on success, a cross while failed. Tapping an
/// in-flight ring calls `onCancel`.
public struct ScanProgressRing: View {
    private let progress: ScanProgress?
    private let state: QRScanner.State
    private let onCancel: () -> Void

    @ScaledMetric(relativeTo: .body) private var dimension: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var lineWidth: CGFloat = 3
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 13

    public init(progress: ScanProgress?, state: QRScanner.State, onCancel: @escaping () -> Void = {}) {
        self.progress = progress
        self.state = state
        self.onCancel = onCancel
    }

    private var fraction: Double {
        switch state {
        case .completed: return 1
        default: return progress?.fraction ?? 0
        }
    }

    private var isVisible: Bool {
        switch state {
        case .completed, .failed: return true
        default: return progress != nil
        }
    }

    private var isInFlight: Bool {
        if case .scanning = state, let progress, !progress.isComplete { return true }
        return false
    }

    public var body: some View {
        Button {
            if isInFlight { onCancel() }
        } label: {
            ZStack {
                Circle()
                    .stroke(lineWidth: lineWidth)
                    .foregroundStyle(.secondary.opacity(0.5))
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: fraction)
                symbol
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .frame(width: dimension, height: dimension)
            .padding(6)
            .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .completed: Image(systemName: "checkmark")
        case .failed: Image(systemName: "exclamationmark")
        default:
            if isInFlight { Image(systemName: "xmark") } else { EmptyView() }
        }
    }

    private var accessibilityText: String {
        switch state {
        case .completed: return "Scan complete"
        case .failed: return "Scan failed"
        default:
            if let progress { return "Scanning, \(Int((progress.fraction * 100).rounded())) percent" }
            return "Scanner"
        }
    }
}
