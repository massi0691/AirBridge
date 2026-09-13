//
//  RadarView.swift
//  AirBridge
//
//  Visual metaphor for the discovery process. Concentric circles, a slow
//  sweep, and the local device at the center. The radar is purely
//  decorative: it does not encode real positions or distances.
//

import SwiftUI

/// Decorative radar view that hosts device bubbles around the local
/// device. Reduce Motion is respected: the sweep freezes, the pulse
/// collapses to a single static ring.
struct RadarView: View {

    let localDevice: Device
    let devices: [DiscoveredDevice]
    let connectedDevice: Device?
    let trustedPeerIDs: Set<UUID>
    @Binding var selectedDeviceID: UUID?

    /// When the view is not on screen, callers can flip this to false
    /// to pause the sweep animation. Default is true.
    var isActive: Bool = true

    /// Whether to enable proximity animation (devices animate toward center)
    var enableProximityAnimation: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ringCount = 4

    /// Taille minimale du radar
    private static let minSize: CGFloat = 180
    /// Taille maximale du radar
    private static let maxSize: CGFloat = 500

    var body: some View {
        GeometryReader { proxy in
            // Calculer la taille adaptative du radar en fonction de l'espace disponible
            let radarSize = Self.calculateRadarSize(for: proxy)
            let radius = radarSize / 2 - AirBridgeDesign.Spacing.lg
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                background

                rings(center: center, radius: radius)

                if !reduceMotion && isActive {
                    sweep(center: center, radius: radius)
                }

                localBubble(center: center)

                ForEach(devices) { device in
                    DeviceRadarItem(
                        device: device,
                        radius: radius,
                        isSelected: selectedDeviceID == device.id,
                        isConnected: connectedDevice?.id == device.id,
                        isTrusted: trustedPeerIDs.contains(device.id),
                        enableProximityAnimation: enableProximityAnimation && (selectedDeviceID == device.id),
                        center: center
                    ) {
                        toggleSelection(device)
                    }
                    .transition(Transitions.radarBubbleAppear)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.8),
                        value: selectedDeviceID
                    )
                }
            }
        }
        .frame(
            minWidth: Self.minSize,
            maxWidth: Self.maxSize,
            minHeight: Self.minSize,
            maxHeight: Self.maxSize,
            alignment: .center
        )
        .aspectRatio(1.0, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    /// Calcule la taille du radar en fonction de l'espace disponible.
    /// - Parameter proxy: GeometryProxy du conteneur parent
    /// - Returns: Taille optimale du radar (carré)
    private static func calculateRadarSize(for proxy: GeometryProxy) -> CGFloat {
        let availableWidth = proxy.size.width
        let availableHeight = proxy.size.height

        // Prendre le minimum entre largeur et hauteur disponibles
        let maxPossibleSize = min(availableWidth, availableHeight)

        // Contraindre entre min et max
        return min(max(maxPossibleSize, minSize), maxSize)
    }

    // MARK: - Subviews

    private var background: some View {
        RadialGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color.clear
            ],
            center: .center,
            startRadius: 16,
            endRadius: 220
        )
        .blendMode(.normal)
    }

    private func rings(center: CGPoint, radius: CGFloat) -> some View {
        ForEach(0..<ringCount, id: \.self) { index in
            let r = radius * CGFloat(index + 1) / CGFloat(ringCount)
            Circle()
                .stroke(
                    Color.secondary.opacity(0.18),
                    lineWidth: 1
                )
                .frame(width: r * 2, height: r * 2)
                .position(center)
        }
    }

    /// Conic gradient sweep — simulates a scanning beam. With Reduce
    /// Motion enabled this view is not inserted (see body).
    private func sweep(center: CGPoint, radius: CGFloat) -> some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color.accentColor.opacity(0.0),
                        Color.accentColor.opacity(0.0),
                        Color.accentColor.opacity(0.18),
                        Color.accentColor.opacity(0.0)
                    ]),
                    center: .center
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
            .rotationEffect(.degrees(isActive ? 360 : 0))
            .animation(
                AirBridgeDesign.radarSweepAnimation,
                value: isActive
            )
            .blendMode(.plusLighter)
    }

    private func localBubble(center: CGPoint) -> some View {
        DeviceAvatarView(
            kind: AirBridgeDesign.DeviceKind.from(model: localDevice.model),
            size: .large,
            state: .selected
        )
        .position(center)
        .accessibilityLabel(Text("\(localDevice.name), cet appareil"))
    }

    // MARK: - Selection

    private func toggleSelection(_ device: DiscoveredDevice) {
        if selectedDeviceID == device.id {
            selectedDeviceID = nil
        } else {
            selectedDeviceID = device.id
        }
    }
}
