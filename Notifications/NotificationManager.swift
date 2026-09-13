//
//  NotificationManager.swift
//  AirBridge
//
//  Created by massi9106 on 24/08/2026.
//

import Foundation
@preconcurrency import UserNotifications
import OSLog

/// Gestionnaire centralisé des notifications locales AirBridge.
///
/// Responsabilités :
/// - Demander et gérer les autorisations de notification
/// - Exposer l'état d'autorisation pour l'UI Settings
/// - Envoyer les notifications pour les événements métier clés
/// - Éviter le spam (pas de notification par chunk, par progression, etc.)
@MainActor
@Observable
final class NotificationManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "notifications"
    )

    // MARK: - Callbacks pour actions de notification

    /// Appelé quand l'utilisateur accepte un transfert entrant via la notification
    var onAcceptTransfer: (() -> Void)?

    /// Appelé quand l'utilisateur refuse un transfert entrant via la notification
    var onRejectTransfer: (() -> Void)?

    // MARK: - État d'autorisation

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Préférence utilisateur (liée à @AppStorage "notificationsEnabled")

    /// Indique si l'utilisateur a activé les notifications dans les réglages de l'app.
    /// Cette préférence est persistée via @AppStorage dans SettingsView.
    /// Le gestionnaire la lit dynamiquement via UserDefaults pour rester synchronisé.
    /// Retourne true par défaut si la clé n'existe pas (cohérence avec @AppStorage default).
    var userNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    // MARK: - Anti-spam / Déduplication

    /// Ensemble des IDs de transfert pour lesquels une notification a déjà été envoyée.
    /// Évite les notifications en double lors de réception redondante du même événement terminal.
    private var notifiedTransferIDs: Set<UUID> = []

    /// Vérifie si une notification peut être envoyée pour cet ID de transfert.
    /// Retourne `true` si c'est la première fois, `false` si déjà notifié.
    func checkNotNotified(_ transferID: UUID) -> Bool {
        if notifiedTransferIDs.contains(transferID) {
            return false
        }
        notifiedTransferIDs.insert(transferID)
        return true
    }

    /// Réinitialise le suivi des notifications (utile pour les tests ou nettoyage).
    func resetNotifiedTransfers() {
        notifiedTransferIDs.removeAll()
    }

    // MARK: - Delegate pour gestion des notifications

    /// Delegate interne pour gérer la présentation en foreground et les actions utilisateur
    private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        weak var manager: NotificationManager?

        init(manager: NotificationManager) {
            self.manager = manager
            super.init()
        }

        // Afficher la notification même quand l'app est au premier plan
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            manager?.logger.debug("Notification willPresent: \(notification.request.identifier, privacy: .public)")
            if #available(iOS 14.0, macOS 11.0, *) {
                completionHandler([.banner, .sound, .list])
            } else {
                completionHandler([.alert, .sound])
            }
        }

        // Gérer les actions utilisateur (boutons Accepter/Refuser)
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let actionIdentifier = response.actionIdentifier
            let categoryIdentifier = response.notification.request.content.categoryIdentifier

            manager?.logger.debug("Notification action: \(actionIdentifier, privacy: .public) for category: \(categoryIdentifier, privacy: .public)")

            Task { @MainActor [weak self] in
                guard let self = self else {
                    completionHandler()
                    return
                }

                if categoryIdentifier == "incomingTransferRequest" {
                    let userInfo = response.notification.request.content.userInfo
                    if let userInfoDict = userInfo as? [String: Any],
                       let transferID = userInfoDict["transferID"] as? UUID {
                        self.manager?.logger.debug("Notification: transferID = \(transferID, privacy: .public)")
                    } else if let transferIDString = userInfo["transferID"] as? String,
                              let transferID = UUID(uuidString: transferIDString) {
                        self.manager?.logger.debug("Notification: transferID (string) = \(transferID, privacy: .public)")
                    }
                    switch actionIdentifier {
                    case "acceptTransfer":
                        self.manager?.logger.debug("Notification: acceptTransfer action reçue")
                        self.manager?.onAcceptTransfer?()
                    case UNNotificationDefaultActionIdentifier:
                        self.manager?.logger.debug("Notification: UNNotificationDefaultActionIdentifier (default = accept)")
                        self.manager?.onAcceptTransfer?()
                    case "rejectTransfer":
                        self.manager?.logger.debug("Notification: rejectTransfer action reçue")
                        self.manager?.onRejectTransfer?()
                    default:
                        self.manager?.logger.warning("Action inconnue: \(actionIdentifier, privacy: .public)")
                    }
                }
                completionHandler()
            }
        }
    }

    // Conserver une référence forte au delegate pour éviter sa désallocation
    @ObservationIgnored
    private var notificationDelegate: NotificationDelegate!

    // MARK: - Initialisation

    init() {
        self.notificationDelegate = NotificationDelegate(manager: self)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        refreshAuthorizationStatus()
    }

    // MARK: - Gestion des autorisations

    /// Vérifie et met à jour le statut d'autorisation courant.
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    /// Demande l'autorisation pour les notifications locales.
    ///
    /// Appelée une fois au premier lancement ou lorsque l'utilisateur active
    /// les notifications depuis les réglages. Ne bloque pas l'application
    /// si l'utilisateur refuse.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            refreshAuthorizationStatus()
            return granted
        } catch {
            logger.error("Erreur demande autorisation notifications : \(error.localizedDescription, privacy: .public)")
            refreshAuthorizationStatus()
            return false
        }
    }

    /// Indique si les notifications sont autorisées et peuvent être affichées.
    /// Vérifie à la fois la préférence utilisateur ET l'autorisation système.
    var areNotificationsEnabled: Bool {
        userNotificationsEnabled && authorizationStatus == .authorized
    }

    /// Indique si l'utilisateur a refusé définitivement (nécessite ouverture des réglages système).
    var isAuthorizationDenied: Bool {
        authorizationStatus == .denied
    }

    // MARK: - Envoi des notifications

    /// Envoie une notification pour une nouvelle demande de transfert entrante.
    /// Style AirDrop : timeSensitive + son, affichée immédiatement dès réception transferRequest.
    func notifyIncomingTransferRequest(
        senderName: String,
        fileCount: Int,
        fileName: String? = nil
    ) {
        #if DEBUG
        logger.debug("notifyIncomingTransferRequest appelé - sender: \(senderName, privacy: .public), fileCount: \(fileCount), areNotificationsEnabled: \(self.areNotificationsEnabled), userNotificationsEnabled: \(self.userNotificationsEnabled), authorizationStatus: \(self.authorizationStatus.rawValue)")
        #endif
        guard areNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transfert entrant"
        content.sound = .default
        if #available(iOS 15.0, macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        if fileCount > 1 {
            content.body = "\(senderName) veut vous envoyer \(fileCount) fichiers"
        } else if let fileName {
            content.body = "\(senderName) veut vous envoyer \(fileName)"
        } else {
            content.body = "\(senderName) veut vous envoyer un fichier"
        }

        content.categoryIdentifier = "incomingTransferRequest"
        content.userInfo = [
            "type": "incomingTransferRequest",
            "senderName": senderName,
            "fileCount": fileCount
        ]

        let identifier = "incoming-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Erreur notification demande entrante : \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Notification demande entrante envoyée : \(identifier, privacy: .public)")
            }
        }
    }

    /// Envoie une notification de transfert terminé (réussi).
    func notifyTransferCompleted(
        direction: TransferNotificationDirection,
        fileCount: Int,
        deviceName: String
    ) {
        #if DEBUG
        logger.debug("notifyTransferCompleted appelé - direction: \(direction.rawValue, privacy: .public), fileCount: \(fileCount), deviceName: \(deviceName, privacy: .public), areNotificationsEnabled: \(self.areNotificationsEnabled), userNotificationsEnabled: \(self.userNotificationsEnabled), authorizationStatus: \(self.authorizationStatus.rawValue)")
        #endif
        guard areNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transfert terminé"
        content.sound = .default

        switch direction {
        case .sent:
            if fileCount > 1 {
                content.body = "\(fileCount) fichiers envoyés à \(deviceName)"
            } else {
                content.body = "1 fichier envoyé à \(deviceName)"
            }
        case .received:
            if fileCount > 1 {
                content.body = "\(fileCount) fichiers reçus depuis \(deviceName)"
            } else {
                content.body = "1 fichier reçu depuis \(deviceName)"
            }
        }

        content.categoryIdentifier = "transferCompleted"
        content.userInfo = [
            "type": "transferCompleted",
            "direction": direction.rawValue,
            "fileCount": fileCount,
            "deviceName": deviceName
        ]

        let identifier = "completed-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Erreur notification transfert terminé : \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Notification transfert terminé envoyée : \(identifier, privacy: .public)")
            }
        }
    }

    /// Envoie une notification d'échec de transfert.
    func notifyTransferFailed(
        fileName: String,
        deviceName: String,
        reason: String? = nil
    ) {
        guard areNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Échec du transfert"
        content.sound = .default

        var message = "Le transfert de « \(fileName) » avec \(deviceName) a échoué"
        if let reason {
            message += " : \(reason)"
        }
        content.body = message

        content.categoryIdentifier = "transferFailed"
        content.userInfo = [
            "type": "transferFailed",
            "fileName": fileName,
            "deviceName": deviceName,
            "reason": reason ?? "Inconnu"
        ]

        let identifier = "failed-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Erreur notification échec transfert : \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Notification échec transfert envoyée : \(identifier, privacy: .public)")
            }
        }
    }

    /// Envoie une notification d'annulation de transfert.
    func notifyTransferCancelled(
        fileName: String,
        deviceName: String,
        cancelledBy: CancellationSource
    ) {
        guard areNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transfert annulé"
        content.sound = .default

        let sourceText: String
        switch cancelledBy {
        case .localUser:
            sourceText = "par vous"
        case .remoteDevice:
            sourceText = "par \(deviceName)"
        case .timeout:
            sourceText = "délai dépassé"
        case .technicalError:
            sourceText = "erreur technique"
        }

        content.body = "Le transfert de « \(fileName) » a été annulé \(sourceText)"

        content.categoryIdentifier = "transferCancelled"
        content.userInfo = [
            "type": "transferCancelled",
            "fileName": fileName,
            "deviceName": deviceName,
            "cancelledBy": cancelledBy.rawValue
        ]

        let identifier = "cancelled-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Erreur notification annulation transfert : \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Notification annulation transfert envoyée : \(identifier, privacy: .public)")
            }
        }
    }

    // MARK: - Configuration des catégories (actions)

    /// Configure les catégories de notifications avec leurs actions.
    ///
    /// Appelée au démarrage de l'application pour enregistrer les catégories
    /// et leurs boutons d'action (ex: "Accepter", "Refuser" pour les demandes).
    func configureCategories() {
        // Action pour accepter une demande de transfert entrante
        let acceptAction = UNNotificationAction(
            identifier: "acceptTransfer",
            title: "Accepter",
            options: [.foreground]
        )

        // Action pour refuser une demande de transfert entrante
        let rejectAction = UNNotificationAction(
            identifier: "rejectTransfer",
            title: "Refuser",
            options: [.destructive]
        )

        // Catégorie pour les demandes entrantes (avec actions)
        let incomingCategory = UNNotificationCategory(
            identifier: "incomingTransferRequest",
            actions: [acceptAction, rejectAction],
            intentIdentifiers: [],
            options: []
        )

        // Catégories pour les événements terminaux (sans actions)
        let completedCategory = UNNotificationCategory(
            identifier: "transferCompleted",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let failedCategory = UNNotificationCategory(
            identifier: "transferFailed",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let cancelledCategory = UNNotificationCategory(
            identifier: "transferCancelled",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            incomingCategory,
            completedCategory,
            failedCategory,
            cancelledCategory
        ])
    }

    // MARK: - Nettoyage

    /// Supprime toutes les notifications AirBridge en attente.
    func removeAllPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Supprime les notifications livrées (affichées dans le centre de notifications).
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

/// Direction du transfert pour la notification.
enum TransferNotificationDirection: String {
    case sent = "sent"
    case received = "received"
}

// MARK: - Types auxiliaires

/// Origine de l'annulation pour le message utilisateur.
enum CancellationSource: String {
    case localUser = "localUser"
    case remoteDevice = "remoteDevice"
    case timeout = "timeout"
    case technicalError = "technicalError"
}