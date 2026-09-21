//
//  SharingDiagnosticsTests.swift
//  AirBridge
//
//  Tests du constructeur pur de diagnostic de partage.
//
//  Le panneau de diagnostic existe pour répondre à une seule question :
//  « pourquoi mon envoi reste-t-il sur En attente alors que le
//  destinataire a accepté ? ». Ces tests verrouillent donc les
//  propriétés qui rendent la réponse exploitable :
//
//    1. un état nominal ne produit **aucune** ligne bloquante (sinon le
//       panneau crierait au loup et perdrait toute valeur) ;
//    2. chaque cause connue de blocage produit exactement une ligne
//       `.failure` **avec** une action correctrice ;
//    3. ce qui n'est pas mesurable depuis l'application (pare-feu,
//       filtrage réseau) est `.unchecked` et ne prétend jamais connaître
//       la réponse ;
//    4. l'ordre des lignes suit la chaîne réelle d'un partage, de la
//       carte réseau jusqu'au menu Partager.
//
//  Le constructeur est pur : aucun réseau, aucun appareil, aucun Core.
//

import XCTest
@testable import AirBridge

@MainActor
final class SharingDiagnosticsTests: XCTestCase {

    // MARK: - Fabriques

    /// État nominal : tout fonctionne, rien à signaler.
    private func makeInput(
        platform: DiagnosticPlatform = .macOS,
        isPathSatisfied: Bool = true,
        isPathExpensive: Bool = false,
        pathSupportsDNS: Bool = true,
        interfaceNames: [String] = ["en0"],
        isLocalNetworkAuthorizationDenied: Bool = false,
        isAdvertisingReady: Bool = true,
        isBrowsingReady: Bool = true,
        bonjourIssue: String? = nil,
        discoveredPeerCount: Int = 1,
        peerName: String? = "iPhone de Camille",
        sessionStateDescription: String = "connecté",
        isSessionReady: Bool = true,
        isSecureSessionReady: Bool = true,
        isPeerRecorded: Bool = true,
        peerTrustState: TrustState = .trusted,
        lastReceptionRejection: ReceptionRejection? = nil,
        embeddedPluginNames: [String] = ["FinderService.appex"],
        isAppGroupContainerAvailable: Bool = true
    ) -> DiagnosticsInput {
        DiagnosticsInput(
            platform: platform,
            isPathSatisfied: isPathSatisfied,
            isPathExpensive: isPathExpensive,
            pathSupportsDNS: pathSupportsDNS,
            interfaceNames: interfaceNames,
            isLocalNetworkAuthorizationDenied: isLocalNetworkAuthorizationDenied,
            isAdvertisingReady: isAdvertisingReady,
            isBrowsingReady: isBrowsingReady,
            bonjourIssue: bonjourIssue,
            discoveredPeerCount: discoveredPeerCount,
            peerName: peerName,
            sessionStateDescription: sessionStateDescription,
            isSessionReady: isSessionReady,
            isSecureSessionReady: isSecureSessionReady,
            isPeerRecorded: isPeerRecorded,
            peerTrustState: peerTrustState,
            lastReceptionRejection: lastReceptionRejection,
            embeddedPluginNames: embeddedPluginNames,
            isAppGroupContainerAvailable: isAppGroupContainerAvailable
        )
    }

    private func item(
        _ items: [DiagnosticItem],
        id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DiagnosticItem {
        try XCTUnwrap(
            items.first { $0.id == id },
            "La ligne de diagnostic « \(id) » est absente du panneau",
            file: file,
            line: line
        )
    }

    // MARK: - État nominal

    /// Rien ne doit être signalé quand la chaîne de partage est intacte :
    /// un panneau qui affiche des alertes en régime normal n'est plus lu.
    func testNominalStateProducesNoBlockingItem() throws {
        let items = SharingDiagnosticsBuilder.items(from: makeInput())

        XCTAssertEqual(
            SharingDiagnosticsBuilder.blockingCount(in: items), 0,
            "Un état nominal ne doit produire aucune ligne bloquante"
        )

        for item in items {
            XCTAssertEqual(
                item.status, .ok,
                "La ligne « \(item.id) » signale un problème alors que l'état est nominal"
            )
            XCTAssertFalse(item.detail.isEmpty)
        }
    }

    /// L'ordre des lignes suit le parcours réel d'un fichier : réseau →
    /// autorisation → découverte → session → pairage → pare-feu → menu
    /// Partager. Le lire de haut en bas revient à suivre le transfert.
    func testItemsFollowTheSharingChainOrder() {
        let ids = SharingDiagnosticsBuilder.items(from: makeInput()).map(\.id)

        XCTAssertEqual(
            ids,
            [
                "network",
                "local-network-permission",
                "discovery",
                "session",
                "pairing",
                "firewall",
                "share-menu"
            ]
        )
    }

    // MARK: - Réseau

    /// Sans chemin réseau, rien ne peut partir : c'est la première cause
    /// de blocage à éliminer, d'où son `.failure` en tête de panneau.
    func testMissingNetworkPathIsBlocking() throws {
        let input = makeInput(
            isPathSatisfied: false,
            interfaceNames: []
        )
        let items = SharingDiagnosticsBuilder.items(from: input)
        let network = try item(items, id: "network")

        XCTAssertEqual(network.status, .failure)
        XCTAssertTrue(
            network.detail.contains("Aucun chemin réseau"),
            "Le détail doit nommer l'absence de chemin réseau : \(network.detail)"
        )
        XCTAssertTrue(
            network.remediation?.contains("Wi-Fi") == true,
            "La correction doit indiquer le même réseau Wi-Fi"
        )
        XCTAssertGreaterThanOrEqual(
            SharingDiagnosticsBuilder.blockingCount(in: items), 1
        )
    }

    /// Un partage de connexion n'empêche pas AirBridge de tourner, mais il
    /// sort les deux appareils du même réseau local : `.warning`, jamais
    /// `.failure`.
    func testExpensivePathIsWarningNotBlocking() throws {
        let input = makeInput(isPathExpensive: true)
        let items = SharingDiagnosticsBuilder.items(from: input)

        XCTAssertEqual(try item(items, id: "network").status, .warning)
        XCTAssertEqual(
            SharingDiagnosticsBuilder.blockingCount(in: items), 0,
            "Un chemin coûteux ne doit pas être compté comme bloquant"
        )
    }

    func testPathWithoutDNSIsWarning() throws {
        let input = makeInput(pathSupportsDNS: false)
        let items = SharingDiagnosticsBuilder.items(from: input)

        XCTAssertEqual(try item(items, id: "network").status, .warning)
        XCTAssertEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 0)
    }

    // MARK: - Autorisation « Réseau local »

    /// Refus d'autorisation = ni découverte ni réception : le transfert
    /// reste bloqué et la correction dépend de la plateforme.
    func testDeniedLocalNetworkPermissionIsBlockingWithPlatformSpecificRemediation() throws {
        for platform in [DiagnosticPlatform.macOS, .iOS] {
            let input = makeInput(
                platform: platform,
                isLocalNetworkAuthorizationDenied: true
            )
            let items = SharingDiagnosticsBuilder.items(from: input)
            let permission = try item(items, id: "local-network-permission")

            XCTAssertEqual(permission.status, .failure, "plateforme : \(platform)")
            XCTAssertTrue(
                permission.remediation?.contains("Réseau local") == true,
                "La correction doit renvoyer vers l'autorisation Réseau local (\(platform))"
            )
            XCTAssertGreaterThanOrEqual(
                SharingDiagnosticsBuilder.blockingCount(in: items), 1
            )
        }

        // macOS ouvre les Réglages Système, iOS les Réglages de l'appareil.
        let macRemediation = try item(
            SharingDiagnosticsBuilder.items(
                from: makeInput(platform: .macOS, isLocalNetworkAuthorizationDenied: true)
            ),
            id: "local-network-permission"
        ).remediation
        let iosRemediation = try item(
            SharingDiagnosticsBuilder.items(
                from: makeInput(platform: .iOS, isLocalNetworkAuthorizationDenied: true)
            ),
            id: "local-network-permission"
        ).remediation

        XCTAssertNotEqual(macRemediation, iosRemediation)
        XCTAssertTrue(macRemediation?.hasPrefix("Réglages Système") == true)
        XCTAssertTrue(iosRemediation?.hasPrefix("Réglages →") == true)
    }

    /// Une erreur Bonjour rapportée sans refus explicite reste un indice,
    /// pas une certitude : `.warning`.
    func testBonjourIssueWithoutDenialIsWarning() throws {
        let input = makeInput(bonjourIssue: "Le service n'a pas pu être publié")
        let items = SharingDiagnosticsBuilder.items(from: input)

        XCTAssertEqual(try item(items, id: "local-network-permission").status, .warning)
        XCTAssertEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 0)
    }

    // MARK: - Découverte

    /// Sans publication, l'appareil ne peut pas **recevoir** : bloquant.
    func testAdvertisingDownIsBlocking() throws {
        let input = makeInput(isAdvertisingReady: false)
        let items = SharingDiagnosticsBuilder.items(from: input)
        let discovery = try item(items, id: "discovery")

        XCTAssertEqual(discovery.status, .failure)
        XCTAssertTrue(discovery.detail.contains("publication inactive"))
        XCTAssertTrue(
            discovery.remediation?.contains("Redémarrez AirBridge") == true,
            "Une publication inactive empêche toute réception : la correction doit être le redémarrage"
        )
    }

    /// Sans recherche, l'appareil ne voit pas le destinataire : bloquant,
    /// mais la correction passe par le radar (et le routeur).
    func testBrowsingDownIsBlockingWithRadarRemediation() throws {
        let input = makeInput(isBrowsingReady: false)
        let items = SharingDiagnosticsBuilder.items(from: input)
        let discovery = try item(items, id: "discovery")

        XCTAssertEqual(discovery.status, .failure)
        XCTAssertTrue(discovery.detail.contains("recherche inactive"))
        XCTAssertTrue(discovery.remediation?.contains("Radar") == true)
    }

    /// Aucun pair visible n'est pas une panne d'AirBridge : l'autre
    /// appareil est peut-être simplement fermé. `.warning`.
    func testNoDiscoveredPeerIsWarningNotBlocking() throws {
        let input = makeInput(discoveredPeerCount: 0)
        let items = SharingDiagnosticsBuilder.items(from: input)

        XCTAssertEqual(try item(items, id: "discovery").status, .warning)
        XCTAssertEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 0)
    }

    // MARK: - Session et pairage

    /// Aucun destinataire sélectionné : l'envoi ne peut pas partir, mais
    /// ce n'est pas un dysfonctionnement → `.warning` côté session,
    /// `.unchecked` côté pairage (il n'y a rien à vérifier).
    func testNoConnectedPeerIsWarningForSessionAndUncheckedForPairing() throws {
        let input = makeInput(
            peerName: nil,
            sessionStateDescription: "déconnecté",
            isSessionReady: false,
            isSecureSessionReady: false
        )
        let items = SharingDiagnosticsBuilder.items(from: input)

        XCTAssertEqual(try item(items, id: "session").status, .warning)
        XCTAssertEqual(try item(items, id: "pairing").status, .unchecked)
        XCTAssertEqual(
            SharingDiagnosticsBuilder.blockingCount(in: items), 0,
            "Aucun pair connecté n'est pas un dysfonctionnement"
        )
    }

    /// Session TCP ouverte mais handshake ECDH inachevé : aucune annonce
    /// de transfert ne peut être envoyée ni acceptée. C'est exactement le
    /// « En attente » permanent rapporté par l'utilisateur.
    func testInsecureSessionIsBlocking() throws {
        let input = makeInput(isSecureSessionReady: false)
        let items = SharingDiagnosticsBuilder.items(from: input)
        let session = try item(items, id: "session")

        XCTAssertEqual(session.status, .failure)
        XCTAssertTrue(
            session.detail.contains("ECDH"),
            "Le détail doit nommer la session sécurisée : \(session.detail)"
        )
        XCTAssertNotNil(session.remediation)
        XCTAssertGreaterThanOrEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 1)
    }

    /// Pair jamais enregistré : son `transferAccepted` est écarté par la
    /// politique d'authentification et l'émetteur reste « En attente ».
    /// Le diagnostic doit le dire avec ces mots-là.
    func testUnrecordedPeerIsBlockingAndExplainsTheWaitingState() throws {
        let input = makeInput(isPeerRecorded: false)
        let items = SharingDiagnosticsBuilder.items(from: input)
        let pairing = try item(items, id: "pairing")

        XCTAssertEqual(pairing.status, .failure)
        XCTAssertTrue(
            pairing.detail.contains("En attente"),
            "Le diagnostic doit relier explicitement le pairage absent au blocage « En attente » : \(pairing.detail)"
        )
        XCTAssertTrue(pairing.remediation?.contains("pairage") == true)
    }

    func testBlockedPeerIsBlocking() throws {
        let input = makeInput(peerTrustState: .blocked)
        let items = SharingDiagnosticsBuilder.items(from: input)
        let pairing = try item(items, id: "pairing")

        XCTAssertEqual(pairing.status, .failure)
        XCTAssertTrue(pairing.detail.contains("bloqué"))
        XCTAssertTrue(pairing.remediation?.contains("Appareils appairés") == true)
    }

    func testTrustedPeerIsOk() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(peerTrustState: .trusted)
        )
        let pairing = try item(items, id: "pairing")

        XCTAssertEqual(pairing.status, .ok)
        XCTAssertNil(pairing.remediation)
    }

    /// Un pair `pending` fonctionne (avec confirmation manuelle) : `.ok`,
    /// mais l'astuce d'activation de l'acceptation automatique est utile.
    func testPendingPeerIsOkWithAutoAcceptHint() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(peerTrustState: .pending)
        )
        let pairing = try item(items, id: "pairing")

        XCTAssertEqual(pairing.status, .ok)
        XCTAssertNotNil(pairing.remediation)
        XCTAssertEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 0)
    }

    func testUnknownTrustStateIsWarning() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(peerTrustState: .unknown)
        )

        XCTAssertEqual(try item(items, id: "pairing").status, .warning)
    }

    // MARK: - Contrôle écarté à la réception

    /// La cause directe du symptôme rapporté : le destinataire a accepté,
    /// mais son `transferAccepted` a été écarté par le pipeline sécurisé.
    /// Cette ligne n'existe que si un rejet a réellement eu lieu.
    func testReceptionRejectionAddsItsOwnBlockingLine() throws {
        let rejection = ReceptionRejection(
            kind: .peerNotPaired,
            messageType: "transferAccepted",
            peerName: "iPhone de Camille"
        )
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(lastReceptionRejection: rejection)
        )
        let line = try item(items, id: "reception-rejection")

        XCTAssertEqual(line.status, .failure)
        XCTAssertEqual(
            line.detail, rejection.userFacingMessage,
            "La ligne doit afficher le message utilisateur du rejet, sans reformulation"
        )
        XCTAssertTrue(
            line.title.contains("iPhone de Camille"),
            "Le pair concerné doit être nommé dans le titre : \(line.title)"
        )
        XCTAssertTrue(
            line.remediation?.contains("En attente") == true,
            "La correction doit rappeler le symptôme « En attente »"
        )
        XCTAssertEqual(
            SharingDiagnosticsBuilder.blockingCount(in: items), 1,
            "Un seul rejet enregistré ne doit produire qu'une ligne bloquante"
        )
    }

    func testNoRejectionLineWhenNothingWasRejected() throws {
        let items = SharingDiagnosticsBuilder.items(from: makeInput())

        XCTAssertNil(
            items.first { $0.id == "reception-rejection" },
            "Aucune ligne « contrôle écarté » ne doit apparaître sans rejet enregistré"
        )
    }

    // MARK: - Pare-feu

    /// Le pare-feu n'est pas lisible depuis une application sandboxée :
    /// la ligne donne les vérifications à faire et ne prétend jamais
    /// connaître l'état.
    func testFirewallIsNeverReportedAsKnownOnIOS() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(platform: .iOS, embeddedPluginNames: ["ShareExtension.appex"])
        )
        let firewall = try item(items, id: "firewall")

        XCTAssertEqual(firewall.status, .unchecked)
        XCTAssertTrue(
            firewall.remediation?.contains("isolation des clients") == true,
            "Sur iOS les blocages viennent du réseau : la correction doit viser la borne Wi-Fi"
        )
    }

    /// Sur macOS, une publication Bonjour active prouve que l'écoute
    /// entrante fonctionne : le pare-feu n'est alors pas en cause.
    func testFirewallIsOkOnMacOSWhenListeningIsEstablished() throws {
        let items = SharingDiagnosticsBuilder.items(from: makeInput(platform: .macOS))

        XCTAssertEqual(try item(items, id: "firewall").status, .ok)
    }

    /// Écoute entrante absente : le pare-feu redevient une hypothèse
    /// plausible, mais non vérifiée depuis l'app → `.unchecked`.
    func testFirewallIsUncheckedOnMacOSWhenListeningIsDown() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(platform: .macOS, isAdvertisingReady: false)
        )

        XCTAssertEqual(try item(items, id: "firewall").status, .unchecked)
    }

    // MARK: - Menu Partager

    func testExpectedShareExtensionNamePerPlatform() {
        XCTAssertEqual(
            SharingDiagnosticsBuilder.expectedShareExtensionName(on: .macOS),
            "FinderService.appex"
        )
        XCTAssertEqual(
            SharingDiagnosticsBuilder.expectedShareExtensionName(on: .iOS),
            "ShareExtension.appex"
        )
        XCTAssertEqual(
            SharingDiagnosticsBuilder.expectedShareExtensionName(on: .other),
            "ShareExtension.appex"
        )
    }

    /// Sans extension embarquée, AirBridge ne peut pas apparaître dans le
    /// menu Partager : bloquant, avec le nom exact attendu.
    func testMissingShareExtensionIsBlockingOnBothPlatforms() throws {
        for (platform, expected) in [
            (DiagnosticPlatform.macOS, "FinderService.appex"),
            (DiagnosticPlatform.iOS, "ShareExtension.appex")
        ] {
            let items = SharingDiagnosticsBuilder.items(
                from: makeInput(platform: platform, embeddedPluginNames: [])
            )
            let shareMenu = try item(items, id: "share-menu")

            XCTAssertEqual(shareMenu.status, .failure, "plateforme : \(platform)")
            XCTAssertTrue(
                shareMenu.detail.contains(expected),
                "Le détail doit nommer l'extension attendue (\(expected)) : \(shareMenu.detail)"
            )
            XCTAssertEqual(SharingDiagnosticsBuilder.blockingCount(in: items), 1)
        }
    }

    /// Extension présente mais conteneur App Group indisponible : les
    /// fichiers partagés ne peuvent pas être remis à l'application.
    func testMissingAppGroupContainerIsBlocking() throws {
        let items = SharingDiagnosticsBuilder.items(
            from: makeInput(isAppGroupContainerAvailable: false)
        )
        let shareMenu = try item(items, id: "share-menu")

        XCTAssertEqual(shareMenu.status, .failure)
        XCTAssertTrue(
            shareMenu.detail.contains(PendingShareController.appGroupIdentifier),
            "Le détail doit nommer l'App Group à vérifier : \(shareMenu.detail)"
        )
    }

    /// La consigne d'accès au menu Partager diffère selon la plateforme :
    /// Finder ▸ Partager sur macOS, feuille de partage système sur iOS.
    func testShareMenuInstructionsArePlatformSpecific() throws {
        let macItems = SharingDiagnosticsBuilder.items(
            from: makeInput(platform: .macOS, embeddedPluginNames: ["FinderService.appex"])
        )
        let iosItems = SharingDiagnosticsBuilder.items(
            from: makeInput(platform: .iOS, embeddedPluginNames: ["ShareExtension.appex"])
        )

        let macDetail = try item(macItems, id: "share-menu").detail
        let iosDetail = try item(iosItems, id: "share-menu").detail

        XCTAssertEqual(try item(macItems, id: "share-menu").status, .ok)
        XCTAssertEqual(try item(iosItems, id: "share-menu").status, .ok)
        XCTAssertTrue(macDetail.contains("Finder"), "macOS doit passer par le Finder : \(macDetail)")
        XCTAssertTrue(iosDetail.contains("Partager"), "iOS doit passer par la feuille de partage : \(iosDetail)")
        XCTAssertFalse(
            macDetail.contains("Fichiers/Photos"),
            "La consigne iOS ne doit pas apparaître sur macOS"
        )
    }

    // MARK: - Cohérence globale

    /// Toute ligne bloquante doit porter une action correctrice : un
    /// diagnostic qui constate sans proposer ne sert à rien.
    func testEveryBlockingLineCarriesARemediation() {
        // Cas dégradé cumulatif : réseau absent, autorisation refusée,
        // découverte inactive, session non sécurisée, pair non enregistré,
        // rejet enregistré, extension manquante.
        let inputs: [DiagnosticsInput] = [
            makeInput(isPathSatisfied: false, interfaceNames: []),
            makeInput(isLocalNetworkAuthorizationDenied: true),
            makeInput(isAdvertisingReady: false, isBrowsingReady: false),
            makeInput(isSecureSessionReady: false),
            makeInput(isPeerRecorded: false),
            makeInput(peerTrustState: .blocked),
            makeInput(
                lastReceptionRejection: ReceptionRejection(
                    kind: .secureSessionNotReady,
                    messageType: "transferAccepted"
                )
            ),
            makeInput(embeddedPluginNames: [], isAppGroupContainerAvailable: false)
        ]

        for input in inputs {
            let items = SharingDiagnosticsBuilder.items(from: input)

            XCTAssertGreaterThanOrEqual(
                SharingDiagnosticsBuilder.blockingCount(in: items), 1,
                "Un état dégradé doit produire au moins une ligne bloquante"
            )

            for item in items where item.status == .failure {
                XCTAssertFalse(
                    item.detail.isEmpty,
                    "La ligne « \(item.id) » est bloquante sans explication"
                )
                XCTAssertNotNil(
                    item.remediation,
                    "La ligne bloquante « \(item.id) » n'indique aucune action correctrice"
                )
            }
        }
    }

    /// Le panneau reste stable quelle que soit la plateforme : mêmes
    /// identifiants, donc même testabilité et même ancrage UI.
    func testItemIdentifiersAreStableAcrossPlatforms() {
        for platform in [DiagnosticPlatform.macOS, .iOS, .other] {
            let ids = SharingDiagnosticsBuilder.items(
                from: makeInput(
                    platform: platform,
                    embeddedPluginNames: [
                        SharingDiagnosticsBuilder.expectedShareExtensionName(on: platform)
                    ]
                )
            ).map(\.id)

            XCTAssertEqual(
                ids,
                [
                    "network",
                    "local-network-permission",
                    "discovery",
                    "session",
                    "pairing",
                    "firewall",
                    "share-menu"
                ],
                "plateforme : \(platform)"
            )
        }
    }
}

// MARK: - Messages utilisateur des rejets

@MainActor
final class ReceptionRejectionMessageTests: XCTestCase {

    /// Chaque famille de rejet doit produire un message non vide qui nomme
    /// le contrôle écarté : c'est ce texte qui apparaît tel quel dans le
    /// panneau de diagnostic.
    func testEveryKindNamesTheRejectedMessageType() {
        for kind in [
            ReceptionRejection.Kind.missingPublicKey,
            .identityMismatch,
            .signatureInvalid,
            .peerNotPaired,
            .keyMismatch,
            .replay,
            .secureSessionNotReady
        ] {
            let rejection = ReceptionRejection(
                kind: kind,
                messageType: "transferAccepted",
                peerName: "iPhone de Camille"
            )
            let message = rejection.userFacingMessage

            XCTAssertFalse(message.isEmpty, "kind : \(kind)")
            XCTAssertTrue(
                message.hasPrefix("transferAccepted écarté"),
                "Le message doit commencer par le type de contrôle écarté (\(kind)) : \(message)"
            )
        }
    }

    /// Type de message inconnu ou absent : le libellé retombe sur une
    /// formulation générique plutôt que sur une chaîne vide.
    func testEmptyMessageTypeFallsBackToGenericLabel() {
        let rejection = ReceptionRejection(kind: .replay, messageType: "")

        XCTAssertTrue(
            rejection.userFacingMessage.hasPrefix("un contrôle écarté"),
            "Message obtenu : \(rejection.userFacingMessage)"
        )
    }

    /// Le pair concerné est optionnel (un rejet peut survenir avant toute
    /// identification) : le message doit rester correct sans lui.
    func testMessageIsCompleteWithoutPeerName() {
        let rejection = ReceptionRejection(
            kind: .peerNotPaired,
            messageType: "transferAccepted",
            peerName: nil
        )

        XCTAssertFalse(rejection.userFacingMessage.isEmpty)
        XCTAssertNil(rejection.peerName)
    }
}
