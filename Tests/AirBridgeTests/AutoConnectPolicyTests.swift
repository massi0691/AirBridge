//
//  AutoConnectPolicyTests.swift
//  AirBridgeTests
//
//  Tests de la politique pure de connexion automatique
//  (`AutoConnectPolicy`) : backoff exponentiel borné, préférence
//  utilisateur, blocage, déconnexion explicite, sessions actives.
//
//  La décision est un test pur — aucun socket réseau — ce qui permet
//  de figer les cas critiques qui ont motivé la revue :
//   - « Connexion automatique » désactivée ⇒ PLUS de reconnexion
//     automatique des pairs de confiance, MAIS les reprises de
//     transfert restent actives ;
//   - pair bloqué / déconnexion explicite : jamais de connexion ;
//   - backoff : 15 s → 240 s plafonné, remis à zéro après succès
//     (compteur de failure réinitialisé par le Core).
//

import XCTest
@testable import AirBridge

final class AutoConnectPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// Tous les paramètres dans l'état « neutre » qui admet une
    /// connexion : aucune session, rien de bloquant, backoff écoulé.
    private func baseInputs(
        hasSession: Bool = false,
        hasPendingResume: Bool = false,
        isTrusted: Bool = true,
        isBlocked: Bool = false,
        isUserDisconnected: Bool = false,
        autoConnectEnabled: Bool = true,
        lastAttempt: Date? = nil,
        failureCount: Int = 0,
        now: Date = Date()
    ) -> (
        hasSession: Bool,
        hasPendingResume: Bool,
        isTrusted: Bool,
        isBlocked: Bool,
        isUserDisconnected: Bool,
        autoConnectEnabled: Bool,
        lastAttempt: Date?,
        failureCount: Int,
        now: Date
    ) {
        (hasSession, hasPendingResume, isTrusted, isBlocked,
         isUserDisconnected, autoConnectEnabled, lastAttempt,
         failureCount, now)
    }

    private func evaluate(
        _ inputs: (
            hasSession: Bool,
            hasPendingResume: Bool,
            isTrusted: Bool,
            isBlocked: Bool,
            isUserDisconnected: Bool,
            autoConnectEnabled: Bool,
            lastAttempt: Date?,
            failureCount: Int,
            now: Date
        )
    ) -> AutoConnectDecision {
        AutoConnectPolicy.evaluate(
            hasSession: inputs.hasSession,
            hasPendingResume: inputs.hasPendingResume,
            isTrusted: inputs.isTrusted,
            isBlocked: inputs.isBlocked,
            isUserDisconnected: inputs.isUserDisconnected,
            autoConnectEnabled: inputs.autoConnectEnabled,
            lastAttempt: inputs.lastAttempt,
            failureCount: inputs.failureCount,
            now: inputs.now
        )
    }

    // MARK: - Règle 1 : session déjà active

    func testSkipsWhenSessionAlreadyActive() {
        let decision = evaluate(
            baseInputs(hasSession: true, isTrusted: true)
        )
        XCTAssertEqual(
            decision,
            .skip(reason: .sessionActive),
            "Une session existante interdit toute seconde connexion."
        )
    }

    // MARK: - Règle 2 : pair bloqué

    func testSkipsBlockedPeerEvenWithPendingResume() {
        let decision = evaluate(
            baseInputs(isTrusted: false, isBlocked: true, hasPendingResume: true)
        )
        XCTAssertEqual(
            decision,
            .skip(reason: .peerBlocked),
            "Un pair bloqué reste bloqué, même avec des reprises en attente."
        )
    }

    // MARK: - Règle 3 : déconnexion explicite

    func testSkipsUserDisconnectedPeer() {
        let decision = evaluate(
            baseInputs(isUserDisconnected: true)
        )
        XCTAssertEqual(
            decision,
            .skip(reason: .userDisconnected),
            "Une déconnexion explicite doit être respectée jusqu'au départ du pair."
        )
    }

    // MARK: - Règle 4 : intérêt (confiance / reprise)

    func testConnectsTrustedPeerByDefault() {
        XCTAssertEqual(
            evaluate(baseInputs()),
            .connect,
            "Pair de confiance, réglage actif, aucun blocage → connexion."
        )
    }

    func testSkipsUntrustedPeerWithoutResume() {
        let decision = evaluate(
            baseInputs(isTrusted: false, hasPendingResume: false)
        )
        XCTAssertEqual(
            decision,
            .skip(reason: .notInteresting),
            "Ni confiance ni reprise : rien à connecter."
        )
    }

    func testSettingDisabledSkipsTrustedPeer() {
        let decision = evaluate(
            baseInputs(autoConnectEnabled: false, isTrusted: true)
        )
        XCTAssertEqual(
            decision,
            .skip(reason: .settingDisabled),
            "« Connexion automatique » désactivée → pas de reconnexion du pair de confiance."
        )
    }

    func testSettingDisabledStillAllowsPendingResume() {
        let decision = evaluate(
            baseInputs(
                autoConnectEnabled: false,
                isTrusted: false,
                hasPendingResume: true
            )
        )
        XCTAssertEqual(
            decision,
            .connect,
            "Les reprises de transfert ne dépendent PAS de la préférence."
        )
    }

    func testSettingDisabledStillAllowsTrustedPeerWithResume() {
        let decision = evaluate(
            baseInputs(
                autoConnectEnabled: false,
                isTrusted: true,
                hasPendingResume: true
            )
        )
        XCTAssertEqual(
            decision,
            .connect,
            "Une reprise en attente prime sur la préférence désactivée."
        )
    }

    // MARK: - Backoff

    func testRetryIntervalGrowsExponentiallyAndCaps() {
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 0),
            15
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 1),
            30
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 2),
            60
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 3),
            120
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 4),
            240,
            "Le plafond est atteint à 240 s."
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: 40),
            240,
            "Le plafond ne dépasse jamais 240 s, quel que soit le nombre d'échecs."
        )
        XCTAssertEqual(
            AutoConnectPolicy.retryInterval(afterFailureCount: -3),
            15,
            "Un compteur négatif est clamé à la base."
        )
    }

    func testBackoffRejectsAttemptInsideWindow() {
        let now = Date()
        let decision = evaluate(
            baseInputs(
                lastAttempt: now.addingTimeInterval(-5),
                failureCount: 1,
                now: now
            )
        )
        guard case .skip(.backoff(let remaining)) = decision else {
            return XCTFail("Attendu : skip(.backoff) — obtenu \(decision)")
        }
        XCTAssertEqual(
            remaining,
            25,
            accuracy: 0.5,
            "30 s de fenêtre − 5 s écoulées ≈ 25 s restantes."
        )
    }

    func testBackoffAllowsAttemptAfterWindow() {
        let now = Date()
        let decision = evaluate(
            baseInputs(
                lastAttempt: now.addingTimeInterval(-16),
                failureCount: 0,
                now: now
            )
        )
        XCTAssertEqual(
            decision,
            .connect,
            "16 s > fenêtre de base de 15 s → nouvelle tentative autorisée."
        )
    }

    func testFirstAttemptHasNoBackoff() {
        XCTAssertEqual(
            evaluate(baseInputs(lastAttempt: nil, failureCount: 5)),
            .connect,
            "Sans tentative précédente en mémoire, aucun backoff."
        )
    }

    // MARK: - Préférence

    func testPreferenceDefaultsToEnabled() {
        let defaults = UserDefaults(suiteName: "AutoConnectPolicyTests")
        defaults?.removeObject(forKey: AutoConnectPolicy.enabledPreferenceKey)
        XCTAssertEqual(
            AutoConnectPolicy.isEnabled(defaults: defaults ?? .standard),
            true,
            "Par défaut, la connexion automatique est active."
        )
    }

    func testPreferenceHonoursExplicitDisable() {
        let defaults = UserDefaults(suiteName: "AutoConnectPolicyTests")
        defaults?.set(
            false,
            forKey: AutoConnectPolicy.enabledPreferenceKey
        )
        XCTAssertEqual(
            AutoConnectPolicy.isEnabled(defaults: defaults ?? .standard),
            false
        )
        defaults?.removeObject(
            forKey: AutoConnectPolicy.enabledPreferenceKey
        )
    }
}
