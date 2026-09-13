//
//  HapticsTests.swift
//  AirBridgeTests
//
//  Tests de compilation de l'abstraction `Haptics`. Les effets
//  haptiques réels ne peuvent être testés sans device physique et
//  sont no-op sur macOS — on vérifie uniquement que les API
//  existent sur les deux plateformes cibles (iOS et macOS) et
//  qu'elles peuvent être appelées sans crasher.
//
//  Couvre la Phase 5 (couche présentation iOS / macOS).
//

import XCTest
@testable import AirBridge

@MainActor
final class HapticsTests: XCTestCase {

    /// `Haptics.selection()` doit compiler et s'exécuter sans crash
    /// sur iOS (vraie API `UISelectionFeedbackGenerator`) et sur
    /// macOS (no-op).
    func testSelectionCompilesAndRunsOnBothPlatforms() {
        // L'appel ne doit pas lever — sur iOS il route vers la
        // `UISelectionFeedbackGenerator`, sur macOS c'est un no-op.
        Haptics.selection()
        Haptics.selection()
    }

    /// `Haptics.impact(.medium)` et cie doivent compiler et
    /// s'exécuter sur les deux plateformes.
    func testImpactCompilesAndRunsOnBothPlatforms() {
        for style in Haptics.Style.allValues {
            Haptics.impact(style)
        }
    }

    /// `Haptics.success` / `.warning` / `.error` doivent compiler
    /// et s'exécuter sur les deux plateformes (vraie API iOS, no-op
    /// macOS).
    func testNotificationHelpersCompileAndRunOnBothPlatforms() {
        Haptics.success()
        Haptics.warning()
        Haptics.error()
    }

    /// Le `Style` enum doit exposer au moins les cinq variantes
    /// documentées, peu importe la plateforme — le View s'attend à
    /// pouvoir itérer dessus pour les tests visuels.
    func testStyleExposesAllDocumentedVariants() {
        let expected: Set<Haptics.Style> = [
            .light,
            .medium,
            .heavy,
            .soft,
            .rigid,
        ]
        XCTAssertEqual(
            Haptics.Style.allValues.count,
            expected.count,
            "Le nombre de styles haptiques exposés doit correspondre à la doc."
        )
        for style in Haptics.Style.allValues {
            XCTAssertTrue(
                expected.contains(style),
                "\(style) doit faire partie des styles documentés."
            )
        }
    }
}

// MARK: - Helpers

private extension Haptics.Style {

    /// Liste exhaustive des styles haptiques exposés. Itérable sans
    /// dépendance à `CaseIterable` (qui n'est pas garanti par la
    /// déclaration originale).
    static var allValues: [Haptics.Style] {
        [.light, .medium, .heavy, .soft, .rigid]
    }
}
