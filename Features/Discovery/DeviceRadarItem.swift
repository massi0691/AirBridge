//
//  DeviceRadarItem.swift
//  AirBridge
//
//  One device's bubble on the radar. L'angle reste deterministe par
//  appareil (hash du device ID) pour que la mise en page soit stable
//  entre les rendus. Le rayon, lui, dépend de la force du signal quand
//  on en a une : un appareil fort est visuellement rapproché du centre,
//  un faible est poussé vers le bord. Sans signal mesuré, on retombe sur
//  le placement par hash et la bulle est marquée comme "non mesurée".
//

import SwiftUI

/// Single device bubble rendered on the radar.
///
/// The angle is computed from a stable hash of the device's UUID, so
/// the same device keeps the same angular slot across re-renders. The
/// radius is driven by the RSSI when one is available (strong → closer
/// to the centre, weak → pushed outward), and falls back to the legacy
/// hash-based radius otherwise — visually flagged so the user can tell
/// the placement is not measured.
struct DeviceRadarItem: View {

    let device: DiscoveredDevice
    let radius: CGFloat
    let isSelected: Bool
    let isConnected: Bool
    let isTrusted: Bool
    /// When true, the bubble animates toward the center (proximity effect)
    var enableProximityAnimation: Bool = false
    /// Center point of the radar, used for proximity animation
    var center: CGPoint = .zero
    let onTap: () -> Void

    /// Plage RSSI considérée comme "utile" par le mapping. -30 dBm =
    /// excellent (quasi collé), -90 dBm = signal faible (poussé au
    /// bord). En dehors de cette plage, on sature aux bornes pour
    /// éviter qu'un signal aberrant (ex. -10 dBm) ne place la bulle
    /// sur l'appareil local.
    private static let rssiExcellent: Double = -30
    private static let rssiWeak: Double = -90

    /// Multiplicateur de rayon minimal et maximal appliqué au `radius`
    /// du radar.
    ///
    /// Bornes resserrées (vs. 0.35 / 0.95 initialement) : la zone
    /// centrale occupe une part beaucoup plus large du cadran, les
    /// appareils restent lisibles au lieu d'être plaqués contre le
    /// bord. Combinées au `visualCompressionFactor` ci-dessous, les
    /// bulles restent près du centre pour qu'on les perçoive
    /// clairement dans le champ du radar.
    #if os(iOS)
    // iOS : appareils plus éloignés pour une meilleure lisibilité visuelle
    private static let minRadiusFactor: Double = 0.15
    private static let maxRadiusFactor: Double = 0.50
    #else
    // macOS : comportement par défaut
    private static let minRadiusFactor: Double = 0.12
    private static let maxRadiusFactor: Double = 0.32
    #endif

    /// Facteur de compression visuelle global appliqué au rayon.
    ///
    /// Historique :
    ///   - `1.0` (placeholder initial)
    ///   - `0.75` (premier resserrement — ramenait un signal médian à
    ///     `~0.34` du rayon, encore trop loin du centre sur la vue)
    ///   - `0.65` (resserrage final — un signal médian tombe à
    ///     `0.32 * 0.65 ≈ 0.21` du rayon, soit ~21% du rayon.
    ///     Les bulles restent distinctes de l'appareil local mais
    ///     franchement plus proches du centre que de la périphérie,
    ///     conformément à l'attente UX AirDrop-like).
    private static let visualCompressionFactor: Double = 0.65

    /// Distance minimale entre deux devices en points (pour la dispersion)
    private static let minimumDeviceDistance: CGFloat = 20

    /// Vrai si on dispose d'un signal mesuré. Sert à la fois au calcul
    /// du rayon et à l'indicateur visuel "non mesuré".
    private var hasRSSI: Bool {
        device.rssi != nil
    }

    private var kind: AirBridgeDesign.DeviceKind {
        AirBridgeDesign.DeviceKind.from(model: device.device.model)
    }

    private var position: CGPoint {
        // Angle deterministe par UUID : la bulle garde son emplacement
        // angulaire entre les rendus, on ne la voit pas "sauter".
        // Les angles sont déjà bien répartis grâce au hash 16-bit par
        // UUID — pas besoin de passe post-calcul pour gérer les
        // collisions, en pratique elles sont rares.
        let hash = abs(device.device.id.uuidString.hashValue)
        let angle = Double((hash & 0xFFFF)) / 65535.0 * 2 * .pi

        // Rayon : piloté par le RSSI si disponible, sinon par le hash
        // (ancien comportement, marqué visuellement comme "non mesuré"
        // — voir `unmeasuredBadge`). `visualCompressionFactor` est un
        // multiplicateur final pour pouvoir resserrer la mise en page
        // sans toucher aux bornes du mapping.
        var distance = radius
            * mappedRadius(rssi: device.rssi)
            * Self.visualCompressionFactor

        // Ajouter un facteur de dispersion pour éviter les chevauchements.
        // Basé sur le hash pour rester déterministe : 0-30% de dispersion
        // supplémentaire selon la tranche du hash.
        let dispersionHash = abs((hash >> 8) & 0xFFFF)
        let dispersion = 1.0 + (Double(dispersionHash) / 65535.0) * 0.3
        distance = distance * dispersion

        // S'assurer que la distance n'est pas trop petite (distance minimale) :
        // plancher historique relatif au rayon (mapping RSSI)…
        let minRadiusDistance = radius * Self.minRadiusFactor * Self.visualCompressionFactor
        // …complété par une distance centre-à-centre qui dégage la bulle de
        // l'avatar local (`.large`, 36 pt de rayon) : la bulle (`.medium`,
        // 28 pt) ne doit pas le chevaucher. Borné au rayon pour rester
        // exploitable sur un radar très petit.
        let minBubbleDistance = min(
            DeviceAvatarView.Size.large.dimension / 2
                + DeviceAvatarView.Size.medium.dimension / 2
                + AirBridgeDesign.Spacing.sm,
            radius * 0.5
        )
        distance = max(distance, minRadiusDistance, minBubbleDistance)

        // La position est exprimée en absolu dans l'espace du ZStack du
        // radar : centre du radar + déplacement polaire, pour que la bulle
        // gravite autour de l'appareil local (et non autour de l'origine du
        // parent, coin supérieur gauche).
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * distance,
            y: center.y + CGFloat(sin(angle)) * distance
        )
    }

    /// Mapping dBm → facteur de rayon dans `[minRadiusFactor,
    /// maxRadiusFactor]`.
    ///
    /// - Signal excellent (-30 dBm) → facteur proche de `min`, donc
    ///   bulle presque collée au centre.
    /// - Signal faible (-90 dBm) → facteur proche de `max`, donc
    ///   bulle poussée au bord.
    /// - Pas de signal (`nil`) → fallback sur le hash, comme avant.
    ///
    /// La courbe est un ease-out (1 − (1 − t)²) pour que les
    /// appareils forts soient franchement près du centre, sans pour
    /// autant que les appareils moyens soient écrasés contre lui.
    private func mappedRadius(rssi: Int?) -> Double {
        Self.mappedRadius(
            rssi: rssi,
            deviceID: device.device.id,
            visualCompressionFactor: Self.visualCompressionFactor
        )
    }

    /// Variante statique, exposée en `internal` pour permettre aux
    /// tests unitaires d'exercer la fonction pure sans monter une
    /// vue SwiftUI. Le calcul est strictement identique à
    /// `mappedRadius(rssi:)` ; seul le `deviceID` est passé en
    /// argument au lieu d'être lu depuis `self.device.device.id`.
    static func mappedRadius(
        rssi: Int?,
        deviceID: UUID,
        visualCompressionFactor: Double
    ) -> Double {
        let base: Double
        if let rssi {
            let dBm = Double(rssi)
            let clamped = min(max(dBm, rssiWeak), rssiExcellent)

            // t ∈ [0, 1] : 0 = excellent (proche du centre), 1 = faible (au bord).
            let t = (clamped - rssiExcellent) / (rssiWeak - rssiExcellent)

            // Ease-out quadratique : les valeurs proches de 0 (signal
            // fort) descendent vite, les valeurs proches de 1
            // s'étalent.
            let eased = 1.0 - (1.0 - t) * (1.0 - t)

            base = minRadiusFactor
                + eased * (maxRadiusFactor - minRadiusFactor)
        } else {
            // Pas de signal : fallback hash, mais on reste dans la
            // zone centrale (entre 0.30 et 0.50) pour ne pas accuser
            // une "faiblesse" qui n'est pas mesurée.
            let hash = abs(deviceID.uuidString.hashValue)
            let normalized = Double((hash >> 16) & 0xFF) / 255.0
            base = 0.30 + normalized * 0.20
        }

        return base * visualCompressionFactor
    }

    private var avatarState: DeviceAvatarView.State {
        if isConnected { return .connected }
        if isSelected { return .selected }
        if isTrusted  { return .trusted }
        return .idle
    }

    /// Position calculée avec effet de proximité.
    /// Si `enableProximityAnimation` est vrai, la bulle anime vers le centre.
    /// Sur macOS, l'appareil connecté est aussi légèrement descendu.
    private var proximityPosition: CGPoint {
        if enableProximityAnimation && center != .zero {
            // Animation vers le centre (effet de proximité)
            let originalDistance = hypot(position.x - center.x, position.y - center.y)
            let targetDistance = originalDistance * 0.15 // Se rapproche à 15% de la distance

            if originalDistance > 0 {
                let ratio = targetDistance / originalDistance
                var x = center.x + (position.x - center.x) * ratio
                var y = center.y + (position.y - center.y) * ratio

                // Descendre légèrement l'appareil connecté (offset proportionnel au rayon)
                if isConnected {
                    y += radius * 0.05  // 5% du rayon du radar
                }

                return CGPoint(x: x, y: y)
            }
        }
        return position
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: AirBridgeDesign.Spacing.xs) {
                DeviceAvatarView(
                    kind: kind,
                    size: isConnected ? .large : .medium,
                    state: avatarState
                )

                HStack(spacing: AirBridgeDesign.Spacing.xs) {
                    Text(device.device.name)
                        .font(AirBridgeDesign.Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 88)
                        .foregroundStyle(.primary)

                    if !hasRSSI {
                        unmeasuredBadge
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(hasRSSI ? 1.0 : 0.72)
        .position(proximityPosition)
        .animation(
            .spring(response: 0.6, dampingFraction: 0.8),
            value: proximityPosition
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(device.device.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Petit indicateur "antenne coupée" affiché à côté du nom quand
    /// on n'a pas de signal mesuré. C'est un signal d'honnêteté : la
    /// position est sur le radar, mais elle n'est pas corrélée à une
    /// métrique réelle.
    private var unmeasuredBadge: some View {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Distance non mesurée"))
    }

    private var accessibilityValue: String {
        switch avatarState {
        case .idle: "Disponible"
        case .selected: "Sélectionné"
        case .connected: "Connecté"
        case .trusted: "Appareil de confiance"
        }
    }
}
