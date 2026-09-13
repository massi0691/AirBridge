//
//  DeviceAvatarView.swift
//  AirBridge
//
//  Visual avatar for a discovered device. Combines an SF Symbol with a
//  soft halo and an optional trust indicator. Pure View, no business
//  state.
//

import SwiftUI

/// Avatar representing a single device in the discovery radar.
///
/// The avatar derives its symbol from `AirBridgeDesign.DeviceKind.from(model:)`,
/// so an iPhone shows `iphone`, an iPad shows `ipad`, a Mac shows
/// `laptopcomputer`, anything else falls back to `desktopcomputer`.
struct DeviceAvatarView: View {

    enum Size {
        case small
        case medium
        case large

        var dimension: CGFloat {
            switch self {
            case .small: 40
            case .medium: 56
            case .large: 72
            }
        }

        var symbolFont: Font {
            switch self {
            case .small: .system(size: 18, weight: .medium)
            case .medium: .system(size: 26, weight: .medium)
            case .large: .system(size: 34, weight: .medium)
            }
        }

        var haloOpacity: Double {
            switch self {
            case .small: 0.35
            case .medium: 0.5
            case .large: 0.65
            }
        }
    }

    enum State {
        case idle
        case selected
        case connected
        case trusted

        var haloColor: Color {
            switch self {
            case .idle: Color.secondary.opacity(0.18)
            case .selected: Color.accentColor.opacity(0.25)
            case .connected: Color.green.opacity(0.30)
            case .trusted: Color.blue.opacity(0.25)
            }
        }

        var glyphColor: Color {
            switch self {
            case .idle: .primary
            case .selected: .accentColor
            case .connected: .green
            case .trusted: .blue
            }
        }
    }

    let kind: AirBridgeDesign.DeviceKind
    var size: Size = .medium
    var state: State = .idle

    var body: some View {
        ZStack {
            Circle()
                .fill(state.haloColor)
                .frame(
                    width: size.dimension,
                    height: size.dimension
                )

            Image(systemName: kind.symbolName)
                .font(size.symbolFont)
                .foregroundStyle(state.glyphColor)
                .accessibilityLabel(kind.accessibilityLabel)
        }
        .animation(AirBridgeDesign.AnimationCurve.quick, value: state)
    }
}
