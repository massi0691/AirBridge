//
//  TransferStatusView.swift
//  AirBridge
//
//  Status badge for a transfer. Pure view : no business state, no
//  Core reference, just a colour, an icon, and a label tied to a
//  `TransferUIStatus`.
//

import SwiftUI

/// Status badge shown next to a transfer row.
///
/// Each status maps to a colour, a SF Symbol and a label, all
/// derived from the design system tokens. The view is deliberately
/// dumb : it does not look up the Core, does not compute anything,
/// just renders.
struct TransferStatusView: View {

    let status: TransferUIStatus

    var body: some View {
        HStack(spacing: AirBridgeDesign.Spacing.xs) {
            Image(systemName: status.symbolName)
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
            Text(status.displayName)
                .font(AirBridgeDesign.Typography.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, AirBridgeDesign.Spacing.sm)
        .padding(.vertical, AirBridgeDesign.Spacing.xs)
        .background(
            Capsule()
                .fill(status.tint.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(
                    status.tint.opacity(0.25),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Statut \(status.displayName)")
    }
}

private extension TransferUIStatus {

    var symbolName: String {
        switch self {
        case .waiting: "hourglass"
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .waiting: AirBridgeDesign.Color.info
        case .active: AirBridgeDesign.Color.accent
        case .completed: AirBridgeDesign.Color.success
        case .failed: AirBridgeDesign.Color.warning
        case .cancelled: AirBridgeDesign.Color.error
        }
    }
}

#if DEBUG
#Preview("Transfer statuses") {
    VStack(alignment: .leading, spacing: 12) {
        TransferStatusView(status: .waiting)
        TransferStatusView(status: .active)
        TransferStatusView(status: .completed)
        TransferStatusView(status: .failed)
        TransferStatusView(status: .cancelled)
    }
    .padding()
}
#endif
