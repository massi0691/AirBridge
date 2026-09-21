//
//
//

import Foundation
import CryptoKit

/// État de confiance d'un pair.
/// Conformance `Equatable` (synthétisée : enum sans valeur
/// associée) — requise par les comparaisons `trustState == .trusted`
/// de la sécurité et des vues ; sans elle elles ne compilent pas.
enum TrustState: String, Codable, Sendable, CaseIterable, Equatable {
    /// Pair jamais vu : aucune interaction, aucune preuve d'identité.
    case unknown

    /// Une demande de pairage a été envoyée ou reçue, en attente de confirmation utilisateur.
    case pending

    /// Pair vérifié : l'empreinte a été confirmée par l'utilisateur.
    /// Les transferts sont acceptés automatiquement.
    case trusted

    /// Pair explicitement bloqué par l'utilisateur.
    /// Toutes les connexions sont refusées.
    case blocked
}

/// Informations de pairage persistées pour un pair.
struct PairingInfo: Codable, Sendable {
    let peerID: UUID
    var peerName: String
    var peerPublicKeyData: Data
    var peerFingerprint: String
    let localPublicKeyData: Data
    let localFingerprint: String
    var trustState: TrustState
    let createdAt: Date
    var lastSeenAt: Date
    var verifiedAt: Date?

    /// Met à jour la date de dernière vue.
    mutating func touch() {
        lastSeenAt = Date()
    }

    /// Marque le pair comme vérifié (empreinte confirmée par l'utilisateur).
    mutating func markVerified() {
        trustState = .trusted
        verifiedAt = Date()
    }

    /// Bloque le pair.
    mutating func block() {
        trustState = .blocked
    }

    /// Réinitialise à l'état inconnu (suppression du pairage).
    mutating func reset() {
        trustState = .unknown
        verifiedAt = nil
    }
}

/// Magasin de pairages persisté dans le Keychain (identités) et UserDefaults (métadonnées).
///
/// Les clés privées ne sont JAMAIS dans UserDefaults. Seules les métadonnées
/// non sensibles (peerID, noms, empreintes, états) sont en UserDefaults.
/// Les clés publiques sont dupliquées ici pour éviter un aller-retour Keychain
/// à chaque vérification d'état.
final class PairingStore {

    private enum UserDefaultsKeys {
        static let pairings = "airbridge.pairings.v1"
    }

    /// Compteur de version incrémenté à chaque modification des pairages.
    /// Permet aux observateurs (views) de détecter les changements.
    private var _version: Int = 0

    /// Version actuelle du store. Change à chaque saveAll().
    /// Utilisé par PairingViewModel pour détecter les changements.
    var version: Int { _version }

    /// Charge tous les pairages connus.
    func loadAll() -> [UUID: PairingInfo] {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.pairings),
              let dict = try? JSONDecoder().decode([String: PairingInfo].self, from: data) else {
            return [:]
        }
        var result: [UUID: PairingInfo] = [:]
        for (key, value) in dict {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        return result
    }

    /// Sauvegarde tous les pairages.
    private func saveAll(_ pairings: [UUID: PairingInfo]) {
        let dict = Dictionary(uniqueKeysWithValues: pairings.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.pairings)
            _version += 1
        }
    }

    /// Récupère l'info de pairage pour un pair, ou nil si inconnue.
    func pairing(for peerID: UUID) -> PairingInfo? {
        loadAll()[peerID]
    }

    /// État de confiance actuel pour un pair.
    func trustState(for peerID: UUID) -> TrustState {
        pairing(for: peerID)?.trustState ?? .unknown
    }

    /// Vrai si le pair est de confiance (transferts auto-acceptés).
    func isTrusted(_ peerID: UUID) -> Bool {
        trustState(for: peerID) == .trusted
    }

    /// Vrai si le pair est bloqué.
    func isBlocked(_ peerID: UUID) -> Bool {
        trustState(for: peerID) == .blocked
    }

    /// Enregistre ou met à jour un pairage après échange de clés réussi.
    /// Appelé quand le handshake cryptographique a validé l'identité du pair.
    ///
    /// Retourne un `PairingUpdateResult` indiquant si c'est une création,
    /// une mise à jour normale, ou un changement de clé (avec rétrogradation
    /// éventuelle de la confiance si le pair était `trusted`).
    @discardableResult
    func recordPairing(
        peerID: UUID,
        peerName: String,
        peerPublicKeyData: Data,
        localIdentity: SecureIdentity
    ) -> PairingUpdateResult {
        var pairings = loadAll()
        let fingerprint = SecureIdentityStore.computeFingerprint(peerPublicKeyData)
        let localFingerprint = localIdentity.fingerprint

        if let existing = pairings[peerID] {
            // Pair déjà connu : vérifier si la clé a changé.
            let keyChanged = existing.peerPublicKeyData != peerPublicKeyData

            var updated = existing
            updated.peerPublicKeyData = peerPublicKeyData
            updated.peerFingerprint = fingerprint
            updated.peerName = peerName
            updated.lastSeenAt = Date()

            if keyChanged {
                // Si le pair était de confiance, on rétrograde vers pending
                // pour forcer une re-confirmation utilisateur.
                if updated.trustState == .trusted {
                    updated.trustState = .pending
                    updated.verifiedAt = nil
                    pairings[peerID] = updated
                    saveAll(pairings)
                    return .keyChangedDowngraded(updated)
                }
                // Pour pending/blocked, on garde l'état mais on signale le changement.
                pairings[peerID] = updated
                saveAll(pairings)
                return .keyChanged(updated)
            }

            // Même clé : mise à jour silencieuse (nom, lastSeenAt).
            pairings[peerID] = updated
            saveAll(pairings)
            return .updated(updated)
        }

        // Nouveau pair.
        let info = PairingInfo(
            peerID: peerID,
            peerName: peerName,
            peerPublicKeyData: peerPublicKeyData,
            peerFingerprint: fingerprint,
            localPublicKeyData: localIdentity.publicKeyData,
            localFingerprint: localFingerprint,
            trustState: .pending,
            createdAt: Date(),
            lastSeenAt: Date(),
            verifiedAt: nil
        )
        pairings[peerID] = info
        saveAll(pairings)
        return .created(info)
    }

    /// Met à jour l'état de confiance (appelé par l'action utilisateur).
    @discardableResult
    func setTrustState(_ state: TrustState, for peerID: UUID) -> PairingInfo? {
        var pairings = loadAll()
        guard var info = pairings[peerID] else { return nil }
        switch state {
        case .trusted:
            info.markVerified()
        case .blocked:
            info.block()
        case .unknown:
            info.reset()
        case .pending:
            info.trustState = .pending
        }
        info.touch()
        pairings[peerID] = info
        saveAll(pairings)
        return info
    }

    /// Supprime un pairage (retour à l'état inconnu).
    func removePairing(for peerID: UUID) {
        var pairings = loadAll()
        pairings.removeValue(forKey: peerID)
        saveAll(pairings)
    }

    /// Met à jour le nom du pair (ex: après découverte Bonjour avec nouveau nom).
    func updatePeerName(_ name: String, for peerID: UUID) {
        var pairings = loadAll()
        guard let existing = pairings[peerID] else { return }
        var info = existing
        info.peerName = name
        info.touch()
        pairings[peerID] = info
        saveAll(pairings)
    }

    /// Vérifie que la clé publique du pair correspond à celle enregistrée.
    /// Retourne true si le pair est connu et la clé correspond (anti-MITM).
    func verifyPeerIdentity(peerID: UUID, publicKeyData: Data) -> Bool {
        guard let pairing = pairing(for: peerID) else { return false }
        return pairing.peerPublicKeyData == publicKeyData
    }
}

/// Payload pour l'échange de clés lors du handshake de pairage.
struct PairingPayload: Codable, Sendable {
    let peerID: UUID
    let peerName: String
    let publicKeyData: Data
    let challenge: Data        // Nonce aléatoire 32 octets
    let signature: Data        // Signature du challenge par la clé privée
    let protocolVersion: Int
}

/// Résultat de la mise à jour d'un pairage.
///
/// Distinction importante :
/// - `created` / `updated` : évolution normale, pas d'alerte utilisateur.
/// - `keyChanged` : la clé publique du pair a changé alors que le pair
///   n'était pas encore de confiance (pending/blocked). L'utilisateur doit
///   confirmer l'identité, mais le pairage peut continuer.
/// - `keyChangedDowngraded` : la clé publique d'un pair **de confiance**
///   a changé. C'est un événement de sécurité critique : la confiance est
///   rétrogradée à `.pending` et l'utilisateur **doit** re-confirmer.
enum PairingUpdateResult {
    case created(PairingInfo)
    case updated(PairingInfo)
    case keyChanged(PairingInfo)
    case keyChangedDowngraded(PairingInfo)
}

/// Résultat de la vérification d'un handshake de pairage.
enum PairingVerificationResult {
    case success(PairingInfo)
    case invalidSignature
    case challengeMismatch
    case protocolVersionMismatch
    case selfPairingAttempt
}

/// Gestionnaire du handshake de pairage (challenge-response).
final class PairingHandshake {

    private let pairingStore: PairingStore

    init(pairingStore: PairingStore) {
        self.pairingStore = pairingStore
    }

    /// Génère un challenge aléatoire de 32 octets.
    static func generateChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Crée un payload de pairage à envoyer au pair.
    /// Inclut notre clé publique, un challenge, et la signature du challenge.
    func createPairingPayload(
        peerID: UUID,
        peerName: String,
        challenge: Data
    ) throws -> PairingPayload {
        let identity = try SecureIdentityStore.ensureIdentity()
        let signature = try SecureIdentityStore.sign(challenge)

        return PairingPayload(
            peerID: peerID,
            peerName: peerName,
            publicKeyData: identity.publicKeyData,
            challenge: challenge,
            signature: signature,
            protocolVersion: ProtocolCompatibility.currentVersion
        )
    }

    /// Vérifie un payload de pairage reçu et enregistre le pairage si valide.
    /// - Parameter payload: Payload reçu du pair
    /// - Parameter expectedChallenge: Challenge qu'on avait envoyé (pour réponse)
    /// - Returns: Résultat de la vérification
    func verifyPairingPayload(
        _ payload: PairingPayload,
        expectedChallenge: Data
    ) -> PairingVerificationResult {
        // Vérifier version de protocole
        guard ProtocolCompatibility.isSupported(payload.protocolVersion) else {
            return .protocolVersionMismatch
        }

        // Empêcher l'auto-pairage
        let localIdentity = try? SecureIdentityStore.loadIdentity()
        if let local = localIdentity,
           local.publicKeyData == payload.publicKeyData {
            return .selfPairingAttempt
        }

        // Vérifier le challenge (réponse à notre challenge)
        if payload.challenge != expectedChallenge {
            return .challengeMismatch
        }

        // Vérifier la signature du challenge par la clé publique du pair
        let valid = SecureIdentityStore.verifySignature(
            payload.signature,
            for: payload.challenge,
            publicKeyData: payload.publicKeyData
        )
        guard valid else {
            return .invalidSignature
        }

        // Tout est bon : enregistrer le pairage. On a déjà chargé l'identité
        // locale plus haut (pour détecter l'auto-pairage) ; on la réutilise
        // plutôt que d'écraser un échec Keychain par un crash.
        let identity: SecureIdentity
        if let existing = localIdentity {
            identity = existing
        } else {
            guard let generated = try? SecureIdentityStore.ensureIdentity() else {
                return .invalidSignature
            }
            identity = generated
        }

        let updateResult = pairingStore.recordPairing(
            peerID: payload.peerID,
            peerName: payload.peerName,
            peerPublicKeyData: payload.publicKeyData,
            localIdentity: identity
        )

        // `recordPairing` peut signaler un changement de clé (`.keyChanged`
        // ou `.keyChangedDowngraded`). Ces cas ne sont pas, à ce stade,
        // des échecs de vérification : la signature ECDSA est valide, la
        // clé publique est cohérente avec elle. On les expose ici via la
        // `PairingInfo` retournée (qui contiendra éventuellement un
        // trustState dégradé), et le code appelant peut décider d'agir.
        // Pour l'instant on extrait simplement la `PairingInfo` et on
        // retourne `.success` ; une évolution future pourra propager
        // l'information de changement de clé au reste de l'app.
        let pairingInfo: PairingInfo
        switch updateResult {
        case .created(let info), .updated(let info),
             .keyChanged(let info), .keyChangedDowngraded(let info):
            pairingInfo = info
        }

        return .success(pairingInfo)
    }

    /// Traite une réponse de pairage reçue (notre challenge signé par le pair).
    /// - Parameter payload: Réponse reçue
    /// - Parameter ourChallenge: Challenge qu'on avait envoyé
    /// - Returns: PairingInfo si succès
    func processPairingResponse(
        _ payload: PairingPayload,
        ourChallenge: Data
    ) -> PairingVerificationResult {
        // Même vérification que verifyPairingPayload mais le challenge
        // est celui qu'on a envoyé (le pair le signe et le renvoie)
        return verifyPairingPayload(payload, expectedChallenge: ourChallenge)
    }

    /// Vérifie un payload de pairage *reçu comme demande entrante* (cas
    /// où le pair initie le pairage) et enregistre le pairage si tout
    /// est valide.
    ///
    /// Contrairement à `verifyPairingPayload`, on n'attend AUCUN challenge
    /// de notre côté : le pair nous envoie un challenge *qu'il a lui-même
    /// généré*, on vérifie que la signature ECDSA de ce challenge par sa
    /// clé privée est valide (donc qu'il possède bien la clé privée
    /// associée à `payload.publicKeyData`), et on l'enregistre.
    ///
    /// Cette méthode est la contrepartie symétrique de
    /// `verifyPairingPayload` : elle permet au répondeur de devenir un
    /// pair authentifié *dès la réception* de la demande, sans attendre
    /// que l'initiateur confirme (l'initiateur a déjà signé un challenge
    /// qu'il a généré lui-même, sa possession de la clé privée est donc
    /// prouvée à la réception).
    func verifyIncomingPairingRequest(
        _ payload: PairingPayload
    ) -> PairingVerificationResult {
        // Vérifier la version de protocole
        guard ProtocolCompatibility.isSupported(payload.protocolVersion) else {
            return .protocolVersionMismatch
        }

        // Empêcher l'auto-pairage
        let localIdentity = try? SecureIdentityStore.loadIdentity()
        if let local = localIdentity,
           local.publicKeyData == payload.publicKeyData {
            return .selfPairingAttempt
        }

        // Vérifier la signature du challenge par la clé publique du pair
        let valid = SecureIdentityStore.verifySignature(
            payload.signature,
            for: payload.challenge,
            publicKeyData: payload.publicKeyData
        )
        guard valid else {
            return .invalidSignature
        }

        // Tout est bon : enregistrer le pairage. On a déjà chargé l'identité
        // locale plus haut (pour détecter l'auto-pairage) ; on la réutilise
        // plutôt que d'écraser un échec Keychain par un crash.
        let identity: SecureIdentity
        if let existing = localIdentity {
            identity = existing
        } else {
            guard let generated = try? SecureIdentityStore.ensureIdentity() else {
                return .invalidSignature
            }
            identity = generated
        }

        let updateResult = pairingStore.recordPairing(
            peerID: payload.peerID,
            peerName: payload.peerName,
            peerPublicKeyData: payload.publicKeyData,
            localIdentity: identity
        )

        // Même logique : extraire la PairingInfo depuis le résultat
        // d'enregistrement (incluant les cas de changement de clé).
        let pairingInfo: PairingInfo
        switch updateResult {
        case .created(let info), .updated(let info),
             .keyChanged(let info), .keyChangedDowngraded(let info):
            pairingInfo = info
        }

        return .success(pairingInfo)
    }
}