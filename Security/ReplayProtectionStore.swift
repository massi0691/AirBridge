//
//  ReplayProtectionStore.swift
//  AirBridge
//
//  Created by massi9106 on 27/08/2026.
//

import Foundation

/// Stockage en mémoire pour la protection anti-replay.
///
/// Ce stockage garde une trace des messages vus récemment identifiés par
/// `(peerID, messageID)`. Il rejette les messages déjà vus (replay) et
/// nettoie automatiquement les entrées expirées selon un TTL configurable.
///
/// La limite de capacité empêche une attaque par épuisement de mémoire.
actor ReplayProtectionStore {

    /// Entrée représentant un message vu.
    private struct Entry {
        let timestamp: Date
    }

    /// Dictionnaire interne : clé = "peerID:messageID" -> entrée
    private var storage: [String: Entry] = [:]

    /// Durée de vie maximale d'une entrée (par défaut 5 minutes = 300 secondes).
    private let ttl: TimeInterval

    /// Nombre maximal d'entrées stockées (par défaut 4096).
    private let maxEntries: Int

    /// Initialise le stockage anti-replay.
    /// - Parameters:
    ///   - ttl: Durée de vie d'une entrée en secondes. Par défaut 300 (5 min).
    ///   - maxEntries: Capacité maximale du stockage. Par défaut 4096.
    init(ttl: TimeInterval = 300, maxEntries: Int = 4096) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Enregistre un message comme vu et détecte les replays.
    ///
    /// - Parameters:
    ///   - peerID: Identifiant du pair émetteur.
    ///   - messageID: Identifiant unique du message.
    /// - Returns: `true` si le message est nouveau, `false` s'il a déjà été vu (replay détecté).
    func observe(peerID: UUID, messageID: UUID) -> Bool {
        let key = makeKey(peerID: peerID, messageID: messageID)
        let now = Date()

        // Nettoyage paresseux des entrées expirées avant insertion
        cleanupExpired(now: now)

        if storage[key] != nil {
            // Déjà vu : replay détecté
            return false
        }

        // Vérification de la capacité avant insertion
        if storage.count >= maxEntries {
            // Suppression de l'entrée la plus ancienne pour faire de la place
            evictOldest()
        }

        storage[key] = Entry(timestamp: now)
        return true
    }

    /// Vide complètement le stockage.
    func reset() {
        storage.removeAll()
    }

    /// Supprime les entrées expirées.
    ///
    /// Cette méthode est appelée automatiquement par `observe`, mais peut
    /// être invoquée manuellement pour un nettoyage proactif.
    func cleanup() {
        let now = Date()
        cleanupExpired(now: now)
    }

    /// Nombre actuel d'entrées stockées.
    var count: Int {
        storage.count
    }

    // MARK: - Private Helpers

    /// Construit la clé composite pour le dictionnaire.
    private func makeKey(peerID: UUID, messageID: UUID) -> String {
        "\(peerID.uuidString):\(messageID.uuidString)"
    }

    /// Supprime les entrées dont le timestamp est antérieur à `now - ttl`.
    private func cleanupExpired(now: Date) {
        let expirationThreshold = now.addingTimeInterval(-ttl)
        storage = storage.filter { $0.value.timestamp > expirationThreshold }
    }

    /// Supprime l'entrée la plus ancienne (par timestamp) pour faire de la place.
    private func evictOldest() {
        guard let oldestKey = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key else {
            return
        }
        storage.removeValue(forKey: oldestKey)
    }
}