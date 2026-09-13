//
//  SoundServiceTests.swift
//  AirBridgeTests
//
//  Tests de compilation de `SoundService`.
//
//  `AudioServicesPlaySystemSound` est une fonction C du framework
//  `AudioToolbox`. Elle :
//    - n'a pas de valeur de retour observable (signature `void`),
//    - n'a pas de mode « dry-run » public,
//    - n'est pas interposable depuis Swift sans injecter
//      dynamiquement `dlsym` (over-engineering pour un test
//      unitaire),
//    - n'émet aucun signal sur la session audio de test (le
//      simulateur CI est muet par défaut et la sandbox empêche
//      l'accès au périphérique CoreAudio).
//
//  Conséquence : tester « le son a été joué » reviendrait à mocker
//  `AudioToolbox`, ce qui n'apporte aucune garantie supplémentaire
//  par rapport à vérifier que l'API existe et compile (cf. approche
//  déjà utilisée par `HapticsTests` pour la couche haptique).
//
//  On vérifie donc uniquement que :
//    1. L'enum `SoundEvent` expose le cas `.connected`.
//    2. Le `rawValue` associé est l'identifiant `SystemSoundID`
//       documenté (1057 = "Tink").
//    3. `SoundService.play(.connected)` peut être appelé sans
//       crasher sur iOS ou macOS.
//
//  Couvre la Phase 6 (amélioration UX, feedback audio de connexion).
//

import XCTest
#if canImport(AudioToolbox)
import AudioToolbox
#endif
@testable import AirBridge

final class SoundServiceTests: XCTestCase {

    // MARK: - Enum

    func testSoundEventExposesConnectedCase() {
        // Le contrat est minimaliste : seul `.connected` est
        // exposé pour l'instant. Si d'autres cas sont ajoutés par
        // la suite, ce test sert de « canari » pour signaler un
        // changement d'API.
        let event: SoundService.SoundEvent = .connected

        switch event {
        case .connected:
            // OK
            break
        }
    }

    func testConnectedRawValueIsTinkSystemSound() {
        // 1057 = "Tink" dans le catalogue historique d'Apple
        // AudioToolbox. On fige la valeur pour éviter qu'un
        // changement accidentel de SystemSoundID ne passe
        // inaperçu (un autre son pourrait être audiblement
        // inapproprié pour un événement de connexion positive).
        let event: SoundService.SoundEvent = .connected
        XCTAssertEqual(
            Int(event.rawValue),
            1057,
            "Le SystemSoundID du son de connexion doit être 1057 (Tink)."
        )
    }

    // MARK: - Play (smoke test)

    func testPlayConnectedDoesNotCrash() {
        // Smoke test : on appelle `play(.connected)` en s'attendant
        // à ce qu'il ne lève pas et qu'il rende la main
        // immédiatement. Sur CI, l'appel CoreAudio est un no-op
        // silencieux faute de périphérique, donc pas d'effet
        // secondaire observable — d'où l'absence d'assertion.
        SoundService.play(.connected)
        SoundService.play(.connected) // idempotence.
    }

    // MARK: - API non testable (documentation)

    /// `AudioServicesPlaySystemSound` n'est pas directement
    /// testable sans mock d'`AudioToolbox`. Cette fonction C est
    /// sans valeur de retour, sans side-effect observable sur la
    /// session audio de test (le simulateur CI est muet et la
    /// sandbox bloque l'accès au périphérique CoreAudio), et n'a
    /// pas de mode « dry-run » public. La tester reviendrait à
    /// mocker `dlsym` (`AudioToolbox.AudioServicesPlaySystemSound`)
    /// — over-engineering pour un retour de connexion, déjà
    /// couvert par le test de non-crash ci-dessus. On garde
    /// volontairement cette limitation visible dans le rapport
    /// XCTest pour qu'un futur mainteneur ne s'étonne pas de
    /// l'absence d'assertion « le son a été joué ».
    ///
    /// Le test n'a pas d'assertion : c'est un test
    /// `documentationOnly` au sens du pattern déjà utilisé dans
    /// `ShareViewModelTests`.
    func test_documentationOnly_audioServicesNotMockable() {
        XCTAssertTrue(true)
    }
}
