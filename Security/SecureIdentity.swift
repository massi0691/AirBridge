//
//
//

import Foundation
import CryptoKit
import Security
import OSLog

/// Identité cryptographique persistée dans le Keychain.
///
/// La clé privée ne quitte jamais le Keychain ; seule la clé publique
/// (et son empreinte) circule sur le réseau. L'ensemble est lié à
/// l'instance de l'application via un identifiant stable dans le Keychain.
struct SecureIdentity: Codable, Sendable {

    let publicKeyData: Data
    let fingerprint: String

    var publicKey: P256.Signing.PublicKey {
        get throws {
            try P256.Signing.PublicKey(x963Representation: publicKeyData)
        }
    }
}

/// Gestionnaire d'identité : génération, lecture, persistance Keychain.
final class SecureIdentityStore {

    private enum KeychainKeys {
        static let service = "com.airbridge.identity"
        static let account = "local-identity"
        static let privateKeyTag = "com.airbridge.identity.privateKey"
        static let publicKeyTag = "com.airbridge.identity.publicKey"
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "security.identity"
    )

    /// Crée ou récupère l'identité locale.
    /// - Returns: L'identité existante ou une nouvelle générée et stockée.
    ///
    /// Si l'identité publique est présente dans le Keychain mais que la clé
    /// privée correspondante est absente (par exemple après une restauration
    /// depuis une sauvegarde iCloud, un wipe partiel du Keychain, ou certains
    /// cas de figure en arrière-plan), on régénère l'ensemble pour garder
    /// les clés publique/privée cohérentes. Sans cela, `sign()` échouerait
    /// ensuite avec `KeychainError.itemNotFound(-25300)` et l'appairage
    /// serait impossible côté pair (les signatures seraient rejetées).
    @discardableResult
    static func ensureIdentity() throws -> SecureIdentity {
        if let existing = try loadIdentity(),
           let _ = loadPrivateKeyIfPresent() {
            return existing
        }
        // L'identité publique est absente OU la clé privée est absente.
        // Dans ce dernier cas, on régénère tout pour rester cohérent.
        if (try? loadIdentity()) != nil {
            // L'identité publique existe mais sans sa clé privée : on
            // l'efface pour repartir d'un état propre avant régénération.
            logger.error("SecureIdentityStore : clé privée absente du Keychain — régénération complète de l'identité")
            wipeIdentityInKeychain()
        }
        return try generateAndStoreIdentity()
    }

    /// Charge l'identité depuis le Keychain si elle existe.
    static func loadIdentity() throws -> SecureIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let identity = try? JSONDecoder().decode(SecureIdentity.self, from: data) else {
            return nil
        }
        return identity
    }

    /// Génère une nouvelle paire de clés P-256, stocke la clé privée dans
    /// le Keychain (non exportable, accessible après déverrouillage) et
    /// persiste l'identité (clé publique + empreinte) en JSON.
    private static func generateAndStoreIdentity() throws -> SecureIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let publicKeyData = publicKey.x963Representation
        let fingerprint = computeFingerprint(publicKeyData)

        // Stocker la clé privée dans le Keychain
        let privateKeyData = privateKey.rawRepresentation
        try storePrivateKeyInKeychain(privateKeyData)

        let identity = SecureIdentity(
            publicKeyData: publicKeyData,
            fingerprint: fingerprint
        )

        // Persister l'identité (publique) en JSON dans le Keychain
        let identityData = try JSONEncoder().encode(identity)
        try storeIdentityInKeychain(identityData)

        return identity
    }

    /// Stocke la clé privée brute dans le Keychain comme GenericPassword
    /// avec protection `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
    /// Cette approche évite les problèmes de conversion SecKey sur iOS Simulator.
    private static func storePrivateKeyInKeychain(_ privateKeyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.privateKeyTag,
            kSecValueData as String: privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Supprimer l'existant s'il y en a un
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore(status)
        }
    }

    /// Récupère la clé privée brute depuis le Keychain pour signature.
    static func loadPrivateKey() throws -> P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.privateKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let keyData = result as? Data else {
            throw KeychainError.itemNotFound(status)
        }

        return try P256.Signing.PrivateKey(rawRepresentation: keyData)
    }

    /// Variante non-throwing de `loadPrivateKey()` utilisée uniquement
    /// par `ensureIdentity()` pour vérifier la présence de la clé privée
    /// sans propager d'exception. Retourne `nil` si la clé est absente
    /// ou inaccessible (par exemple après un wipe partiel du Keychain).
    private static func loadPrivateKeyIfPresent() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.privateKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let keyData = result as? Data else {
            return nil
        }
        return keyData
    }

    /// Supprime l'identité publique (et, par défense, la clé privée) du
    /// Keychain. Utilisé par `ensureIdentity()` lorsqu'on détecte un état
    /// incohérent (clé privée manquante) avant de régénérer.
    private static func wipeIdentityInKeychain() {
        let publicQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.account
        ]
        SecItemDelete(publicQuery as CFDictionary)

        let privateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.privateKeyTag
        ]
        SecItemDelete(privateQuery as CFDictionary)
    }

    /// Persiste l'identité (publique) en JSON dans un GenericPassword.
    private static func storeIdentityInKeychain(_ identityData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: KeychainKeys.account,
            kSecValueData as String: identityData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore(status)
        }
    }

    /// Calcule l'empreinte SHA-256 tronquée (16 premiers octets, hex)
    /// pour affichage utilisateur et vérification manuelle.
    static func computeFingerprint(_ publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        let truncated = Data(hash.prefix(16))
        return truncated.map { String(format: "%02x", $0) }.joined()
    }

    /// Vérifie une signature avec la clé publique donnée.
    static func verifySignature(
        _ signature: Data,
        for data: Data,
        publicKeyData: Data
    ) -> Bool {
        do {
            let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
            let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            return publicKey.isValidSignature(ecdsaSignature, for: data)
        } catch {
            return false
        }
    }

    /// Signe des données avec la clé privée locale.
    static func sign(_ data: Data) throws -> Data {
        let privateKey = try loadPrivateKey()
        return try privateKey.signature(for: data).rawRepresentation
    }
}

/// Erreurs liées au Keychain.
enum KeychainError: Error, CustomStringConvertible {
    case unableToStore(OSStatus)
    case itemNotFound(OSStatus)
    case unableToExtractKey(CFError?)

    var description: String {
        switch self {
        case .unableToStore(let status):
            return "Impossible de stocker dans le Keychain : \(status)"
        case .itemNotFound(let status):
            return "Clé privée introuvable dans le Keychain : \(status)"
        case .unableToExtractKey(let error):
            return "Impossible d'extraire la clé : \(error?.localizedDescription ?? "inconnue")"
        }
    }
}