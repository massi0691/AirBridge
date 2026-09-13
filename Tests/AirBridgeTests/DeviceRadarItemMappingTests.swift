//
//  DeviceRadarItemMappingTests.swift
//  AirBridgeTests
//
//  Tests unitaires du mapping RSSI → rayon visuel du radar, après
//  le resserrement des bornes opéré lors de la phase UX
//  AirDrop-like. On vérifie que :
//
//   - `mappedRadius(rssi:)` sature bien sur les bornes
//     `[0.20, 0.55]` pour les valeurs extrêmes de RSSI ;
//   - les valeurs intermédiaires suivent la courbe ease-out et
//     restent dans l'enveloppe ;
//   - le fallback hash pour `rssi == nil` reste dans la zone
//     `[0.30, 0.50]` (anneau central) ;
//   - le `visualCompressionFactor` s'applique en multiplicateur
//     final (placeholder `1.0` aujourd'hui).
//
//  Le mapping est testé via la fonction pure exposée
//  `DeviceRadarItem.mappedRadius(rssi:deviceID:visualCompressionFactor:)`.
//  La View elle-même est SwiftUI et n'est pas exercée ici (couverture
//  visuelle = snapshot testing, hors périmètre unitaire).
//
//  Couvre la Phase UX AirDrop-like (compression du radar).
//

import XCTest
@testable import AirBridge

final class DeviceRadarItemMappingTests: XCTestCase {

    // MARK: - Bornes documentées

    /// Bornes effectives du mapping après le refactor UX
    /// AirDrop-like. Centralisées ici pour qu'une évolution des
    /// constantes dans `DeviceRadarItem` soit visible immédiatement
    /// dans le test (le contrat est "anneau central = 30% du rayon").
    private let minRadiusFactor: Double = 0.12
    private let maxRadiusFactor: Double = 0.32

    private let hashFallbackMin: Double = 0.30
    private let hashFallbackMax: Double = 0.50

    /// Facteur de compression visuelle appliqué en multiplicateur
    /// final sur le rayon. Historique :
    ///   - `1.0` (placeholder initial)
    ///   - `0.75` (premier resserrement)
    ///   - `0.65` (resserrage final — un signal médian tombe à
    ///     `0.32 * 0.65 ≈ 0.21` du rayon, soit ~21% du rayon.
    private let defaultVisualFactor: Double = 0.65

    /// Enveloppe effective = bornes * `defaultVisualFactor`. Gardée
    /// à jour pour que les assertions restent lisibles.
    private var effectiveMin: Double { minRadiusFactor * defaultVisualFactor }
    private var effectiveMax: Double { maxRadiusFactor * defaultVisualFactor }

    // MARK: - Saturation

    /// RSSI excellent (-30 dBm) → facteur proche de `minRadiusFactor`
    /// (bulle presque collée au centre). C'est la convention retenue :
    /// un signal fort rapproche la bulle du centre, un signal faible
    /// la pousse au bord. La courbe ease-out retourne exactement la
    /// borne `min` à `t = 0` (excellent). Avec le
    /// `visualCompressionFactor` par défaut (`0.65`), la valeur
    /// effective est `0.12 * 0.65 ≈ 0.078`.
    func testMappedRadiusAtExcellentSignalIsNearMin() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -30,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertEqual(
            value,
            effectiveMin,
            accuracy: 0.0001,
            "-30 dBm (excellent) doit produire ~0.078 (min compressé)."
        )
    }

    /// RSSI faible (-90 dBm) → facteur proche de `maxRadiusFactor`
    /// (bulle poussée au bord). La courbe ease-out retourne
    /// exactement la borne `max` à `t = 1` (faible). Avec le
    /// facteur de compression, la valeur effective est
    /// `0.32 * 0.65 ≈ 0.208`.
    func testMappedRadiusAtWeakSignalIsNearMax() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -90,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertEqual(
            value,
            effectiveMax,
            accuracy: 0.0001,
            "-90 dBm (faible) doit produire ~0.208 (max compressé)."
        )
    }

    /// RSSI au-dessus du seuil excellent (ex. -10 dBm, sursaturation
    /// ou mesure aberrante) doit saturer à `minRadiusFactor`. Sans
    /// la saturation, le rayon serait inférieur à la borne et la
    /// bulle s'écraserait sur le point central. On vérifie la valeur
    /// effective après application du facteur de compression.
    func testMappedRadiusClampsAboveExcellent() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -10,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertEqual(
            value,
            effectiveMin,
            accuracy: 0.0001,
            "RSSI > -30 dBm doit saturer à la borne min compressée."
        )
    }

    /// RSSI sous le seuil faible (ex. -100 dBm) doit saturer à
    /// `maxRadiusFactor`. Sans la saturation, la formule
    /// `t = (clamped - excellent) / (weak - excellent)` produirait
    /// un `t > 1` et un rayon au-delà de la borne `max`.
    func testMappedRadiusClampsBelowWeak() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -100,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertEqual(
            value,
            effectiveMax,
            accuracy: 0.0001,
            "RSSI < -90 dBm doit saturer à la borne max compressée."
        )
    }

    // MARK: - Médian

    /// RSSI médian (-60 dBm, milieu de la plage) doit produire une
    /// valeur strictement entre les deux bornes. On vérifie aussi
    /// qu'elle est plus proche du `max` que du `min` à cause de la
    /// courbe ease-out (les valeurs proches de `t = 1` descendent vite).
    func testMappedRadiusAtMedianSignalIsBetweenBounds() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -60,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertGreaterThan(
            value,
            effectiveMin,
            "-60 dBm ne doit pas s'écraser sur la borne min compressée."
        )
        XCTAssertLessThan(
            value,
            effectiveMax,
            "-60 dBm ne doit pas s'écraser sur la borne max compressée."
        )
        // Ease-out : à mi-chemin en RSSI (`t = 0.5`), `eased = 0.75`,
        // donc on est plus près du `max` que du `min`.
        let midpoint = (effectiveMin + effectiveMax) / 2
        XCTAssertGreaterThan(
            value,
            midpoint,
            "Ease-out doit pousser la médiane au-dessus du midpoint strict."
        )
    }

    // MARK: - Fallback hash (pas de signal)

    /// Sans RSSI, on retombe sur le placement par hash de l'UUID du
    /// device. La valeur doit rester dans la zone centrale
    /// `[0.30, 0.50]` *avant* application du `visualCompressionFactor`
    /// (l'enveloppe est définie en valeur "absolue"). Le test utilise
    /// `factor == 1.0` pour vérifier l'enveloppe pure, ce qui
    /// correspond à la même sémantique qu'avant le refactor de
    /// compression visuelle.
    func testMappedRadiusWithoutRSSIFallsInCentralRing() {
        for _ in 0..<50 {
            let deviceID = UUID()
            let value = DeviceRadarItem.mappedRadius(
                rssi: nil,
                deviceID: deviceID,
                visualCompressionFactor: 1.0
            )
            XCTAssertGreaterThanOrEqual(
                value,
                hashFallbackMin,
                "Fallback hash doit rester >= 0.30 (UUID \(deviceID))."
            )
            XCTAssertLessThanOrEqual(
                value,
                hashFallbackMax,
                "Fallback hash doit rester <= 0.50 (UUID \(deviceID))."
            )
        }
    }

    /// Le fallback doit être **déterministe** par UUID : le même UUID
    /// produit toujours la même valeur (l'angle est déjà déterministe
    /// par hash, le rayon doit l'être aussi). Sans cet invariant, la
    /// position angulaire d'un appareil "sauterait" entre les
    /// rendus.
    func testMappedRadiusHashFallbackIsDeterministicPerUUID() {
        let deviceID = UUID()
        let first = DeviceRadarItem.mappedRadius(
            rssi: nil,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        let second = DeviceRadarItem.mappedRadius(
            rssi: nil,
            deviceID: deviceID,
            visualCompressionFactor: defaultVisualFactor
        )
        XCTAssertEqual(
            first,
            second,
            accuracy: 0.0001,
            "Le fallback hash doit être stable pour un même UUID."
        )
    }

    // MARK: - Visual compression factor

    /// Le `visualCompressionFactor` est un multiplicateur final. Avec
    /// `factor == 0.7` et un signal excellent (-30 dBm → min), le
    /// rayon doit être `0.12 * 0.7 = 0.084`.
    func testMappedRadiusAppliesVisualCompressionFactor() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -30,
            deviceID: deviceID,
            visualCompressionFactor: 0.7
        )
        XCTAssertEqual(
            value,
            minRadiusFactor * 0.7,
            accuracy: 0.0001,
            "Le facteur 0.7 doit s'appliquer en multiplicateur final."
        )
    }

    /// Le `visualCompressionFactor` doit également compresser le
    /// maximum (multiplicatif). À -90 dBm, le rayon doit être
    /// `0.32 * 0.5 = 0.16`.
    func testMappedRadiusAtWeakSignalWithCompression() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -90,
            deviceID: deviceID,
            visualCompressionFactor: 0.5
        )
        XCTAssertEqual(
            value,
            maxRadiusFactor * 0.5,
            accuracy: 0.0001,
            "Le facteur 0.5 doit également compresser le max."
        )
    }

    /// Avec `factor == 1.0` (toutes bornes ramenées à leur valeur
    /// nominale), le rayon doit rester dans l'enveloppe
    /// `[minRadiusFactor, maxRadiusFactor]`. Test de non-régression :
    /// le facteur unitaire ne doit pas transformer la sortie.
    func testMappedRadiusWithUnitFactorIsUnchanged() {
        let deviceID = UUID()
        let value = DeviceRadarItem.mappedRadius(
            rssi: -45,
            deviceID: deviceID,
            visualCompressionFactor: 1.0
        )
        XCTAssertGreaterThan(
            value,
            minRadiusFactor,
            "À -45 dBm, on est au-dessus de la borne min."
        )
        XCTAssertLessThan(
            value,
            maxRadiusFactor,
            "À -45 dBm, on est en-dessous de la borne max."
        )
    }
}
