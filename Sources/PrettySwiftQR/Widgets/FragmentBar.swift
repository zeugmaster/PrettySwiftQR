//
//  FragmentBar.swift
//  PrettySwiftQR
//

import SwiftUI
import PrettyQRCore

/// One segment per fountain fragment: received, just received, pending, or in
/// the frame currently shown. Works for both display and scan progress.
public struct FragmentBar: View {
    private let states: [ScanProgress.FragmentState]
    private let tint: Color

    public init(states: [ScanProgress.FragmentState], tint: Color = .accentColor) {
        self.states = states
        self.tint = tint
    }

    /// Scan-side progress.
    public init(progress: ScanProgress?, tint: Color = .accentColor) {
        self.init(states: progress?.fragmentStates ?? [], tint: tint)
    }

    /// Display-side: which fragments the frame on screen contains.
    public init(fragmentCount: Int, current: Set<Int>, tint: Color = .accentColor) {
        self.init(states: (0..<fragmentCount).map { current.contains($0) ? .inLastFrame : .missing }, tint: tint)
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Rectangle()
                    .fill(color(for: state))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .animation(.linear(duration: 0.1), value: states)
        .accessibilityLabel("\(states.filter { $0 == .received || $0 == .justReceived }.count) of \(states.count) fragments")
    }

    private func color(for state: ScanProgress.FragmentState) -> Color {
        switch state {
        case .missing: return tint.opacity(0.2)
        case .received: return tint.opacity(0.7)
        case .justReceived: return .white
        case .inLastFrame: return tint
        }
    }
}
