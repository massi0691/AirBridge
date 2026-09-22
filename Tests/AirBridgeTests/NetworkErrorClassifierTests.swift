//
//  NetworkErrorClassifierTests.swift
//  AirBridgeTests
//
//  Tests du classificateur d'erreurs réseau : la frontière entre
//  `.interrupted` (reprisable) et `.failed` (définitif).
//
//  Une erreur de classification a deux conséquences symétriques et
//  opposées :
//   - classifier une rupture de liaison en échec définitif → un
//     transfert pourtant récupérable est perdu ;
//   - classifier une erreur métier en interruption → une boucle de
//  reprises qui rééchouent à l'identique.
//  Les tests figent donc les deux directions de la décision.
//

import XCTest
import Network
@testable import AirBridge

final class NetworkErrorClassifierTests: XCTestCase {

    // MARK: - Erreurs métier : définitives

    func testEncodingErrorIsNotRecoverable() {
        let cause = NSError(domain: "AirBridgeTests", code: 42)
        let error = OutgoingTransferManager.OutgoingTransferManagerError
            .encodingError(cause)

        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
            "Une erreur d'encodage se reproduit à l'identique : définitive."
        )
    }

    func testBusinessErrorWrappedInSendErrorIsNotRecoverable() {
        // `sendError` emballe la cause brute : c'est elle qui décide.
        let cause = NSError(domain: "AirBridgeTests", code: 7)
        let error = OutgoingTransferManager.OutgoingTransferManagerError
            .sendError(cause)

        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
            "Une cause métier encapsulée reste définitive."
        )
    }

    func testUnknownOutgoingErrorIsNotRecoverable() {
        // Cas non répertorié : la règle par défaut est l'échec définitif.
        let error = NSError(domain: "AirBridgeTests", code: 99)

        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
            "Une erreur inconnue ne présume pas d'une liaison perdue."
        )
    }

    // MARK: - Perte de liaison : récupérable

    func testConnectionManagerErrorsAreRecoverable() {
        // Gardes internes (session absente au moment de l'envoi) : la
        // liaison est perdue, le transfert reste reprisable.
        let cases: [ConnectionManager.ConnectionManagerError] = [
            .noActiveConnection,
            .authenticationUnavailable,
            .secureSessionNotReady,
            .encodingError(NSError(domain: "AirBridgeTests", code: 1))
        ]

        for error in cases {
            XCTAssertTrue(
                NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
                "Erreur ConnectionManager attendue comme interruption : \(error)"
            )
        }
    }

    func testRecoverableOutgoingErrors() {
        let recoverable: [OutgoingTransferManager.OutgoingTransferManagerError] = [
            .noActiveConnection,
            .secureSessionNotReady,
            .sourceNotFound,
            .fileNotFound
        ]

        for error in recoverable {
            XCTAssertTrue(
                NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
                "Erreur sortante attendue comme interruption : \(error)"
            )
        }
    }

    func testNetworkErrorWrappedInSendErrorIsRecoverable() {
        let cause = URLError(.networkConnectionLost)
        let error = OutgoingTransferManager.OutgoingTransferManagerError
            .sendError(cause)

        XCTAssertTrue(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
            "ECONNRESET vu à travers sendError reste une interruption."
        )
    }

    // MARK: - Codes POSIX

    func testRecoverablePOSIXCodes() {
        let codes: [POSIXErrorCode] = [
            .ECONNRESET,
            .ENOTCONN,
            .ETIMEDOUT,
            .EHOSTUNREACH,
            .ENETUNREACH,
            .ENETDOWN,
            .ECANCELED,
            .EPIPE
        ]

        for code in codes {
            XCTAssertTrue(
                NetworkErrorClassifier.isRecoverableNetworkInterruption(
                    POSIXError(code)
                ),
                "Code POSIX récupérable : \(code)"
            )
        }
    }

    func testPermanentPOSIXCodeIsNotRecoverable() {
        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(
                POSIXError(.EPERM)
            ),
            "EPERM n'est pas une perte de liaison."
        )
    }

    func testNWErrorPOSIXIsRecoverable() {
        XCTAssertTrue(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(
                NWError.posix(.ECONNRESET)
            )
        )
    }

    func testNSErrorWithPOSIXDomainIsRecoverable() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ETIMEDOUT)
        )

        XCTAssertTrue(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error)
        )
    }

    func testNSErrorWithUnknownPOSIXCodeIsNotRecoverable() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EPERM)
        )

        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error)
        )
    }

    // MARK: - URLError

    func testRecoverableURLCodes() {
        let codes: [URLError.Code] = [
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotFindHost,
            .cannotConnectToHost,
            .timedOut,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .dataNotAllowed
        ]

        for code in codes {
            XCTAssertTrue(
                NetworkErrorClassifier.isRecoverableNetworkInterruption(
                    URLError(code)
                ),
                "URLError récupérable : \(code)"
            )
        }
    }

    func testPermanentURLCodeIsNotRecoverable() {
        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(
                URLError(.badURL)
            ),
            "badURL est une erreur d'usage, pas une perte de liaison."
        )
    }

    // MARK: - Fallback sur le message

    func testKnownNetworkMessagesAreRecoverable() {
        let messages = [
            "Connection reset by peer",
            "No route to host",
            "Network connection lost",
            "The operation couldn’t be completed. Socket is not connected",
            "broken pipe",
            "Operation canceled",
            "Operation cancelled",
            "Host unreachable",
            "The network is down."
        ]

        for message in messages {
            let error = NSError(
                domain: "AirBridgeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )

            XCTAssertTrue(
                NetworkErrorClassifier.isRecoverableNetworkInterruption(error),
                "Message réseau connu non reconnu : « \(message) »"
            )
        }
    }

    func testUnknownMessageIsNotRecoverable() {
        let error = NSError(
            domain: "AirBridgeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fichier introuvable"]
        )

        XCTAssertFalse(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error)
        )
    }

    func testMessageMatchingIsCaseInsensitive() {
        let error = NSError(
            domain: "AirBridgeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "CONNECTION RESET"]
        )

        XCTAssertTrue(
            NetworkErrorClassifier.isRecoverableNetworkInterruption(error)
        )
    }
}
