//
//  ReceivedFolderStore.swift
//  AirBridge
//
//  Created by massi9106 on 26/07/2026.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ReceivedFolderStore {

    private enum Keys {
        static let bookmark = "airbridge.received-folder-bookmark"
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "storage"
    )

    private(set) var selectedDirectory: URL?

    init() {
        restoreDirectory()
    }

    func selectDirectory(_ url: URL) {
        #if os(macOS)

        let hasAccess = url.startAccessingSecurityScopedResource()

        guard hasAccess else {
            logger.error("Accès au dossier sélectionné refusé : \(url.path, privacy: .public)")
            return
        }

        defer {
            url.stopAccessingSecurityScopedResource()
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            UserDefaults.standard.set(
                bookmarkData,
                forKey: Keys.bookmark
            )

            selectedDirectory = url

            logger.info("Dossier de réception enregistré : \(url.path, privacy: .public)")

        } catch {
            logger.error("Impossible d’enregistrer le dossier : \(error.localizedDescription, privacy: .public)")
        }

        #endif
    }
    func clearDirectory() {
        UserDefaults.standard.removeObject(
            forKey: Keys.bookmark
        )

        selectedDirectory = nil

        logger.info("Dossier de réception oublié")
    }

    private func restoreDirectory() {
        #if os(macOS)

        guard let bookmarkData = UserDefaults.standard.data(
            forKey: Keys.bookmark
        ) else {
            return
        }

        do {
            var isStale = false

            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            selectedDirectory = url

            if isStale {
                selectDirectory(url)
            }

            logger.info("Dossier restauré : \(url.path, privacy: .public)")

        } catch {
            logger.error("Impossible de restaurer le dossier : \(error.localizedDescription, privacy: .public)")
            clearDirectory()
        }

        #endif
    }
    
    
}
