//
//  Device.swift
//  AirBridge
//
//  Created by massi9106 on 19/07/2026.
//

import Foundation
import Network

struct Device: Identifiable, Codable, Sendable, Equatable {

    let id: UUID
    let name: String
    let model: String
    let systemVersion: String

    /// Clé publique de signature long-terme (P-256, format
    /// `x963Representation`, 65 octets) de ce device.
    ///
    /// Renseignée par l'émetteur dans **chaque** message sortant
    /// (`sender.publicKeyData`) pour permettre au récepteur de
    /// vérifier la signature des messages qui ne transportent pas
    /// la clé dans leur payload (`hello`, `keyExchange`,
    /// `keyExchangeAck`, `acknowledgement`, `ping`, `pong`).
    ///
    /// `nil` si :
    /// - le sender est un client v1 (ancien, sans clé embarquée
    ///   dans le `Device`) ;
    /// - le device a été reconstruit factice (ex. décode d'un
    ///   `fileChunk` binaire v2 où le sender n'est pas transporté) ;
    /// - le chargement de `SecureIdentity` a échoué au démarrage
    ///   (très rare : keychain corrompue). Dans ce dernier cas, le
    ///   signataire ne peut pas signer ses messages sortants et la
    ///   chaîne de sécurité tombe en fallback dégradé.
    ///
    /// La désérialisation reste compatible avec les anciens clients
    /// qui n'envoient pas ce champ : Swift `Codable` accepte un
    /// `Data?` absent en JSON et l'expose comme `nil`.
    let publicKeyData: Data?

    /// Initialisation complète — utilisée principalement par
    /// `LocalDeviceFactory` qui connaît la clé long-terme chargée
    /// depuis le Keychain.
    init(
        id: UUID,
        name: String,
        model: String,
        systemVersion: String,
        publicKeyData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.publicKeyData = publicKeyData
    }

    /// Initialisation rétro-compatible — un `Device` sans clé
    /// long-terme (par exemple dans les tests ou pour un sender
    /// factice d'un `fileChunk` binaire v2). Le `publicKeyData`
    /// est `nil`.
    init(
        id: UUID,
        name: String,
        model: String,
        systemVersion: String
    ) {
        self.init(
            id: id,
            name: name,
            model: model,
            systemVersion: systemVersion,
            publicKeyData: nil
        )
    }

    var hasKnownModel: Bool {
        model != "Appareil inconnu"
    }

    var hasKnownSystemVersion: Bool {
        systemVersion != "Inconnue"
    }
}
