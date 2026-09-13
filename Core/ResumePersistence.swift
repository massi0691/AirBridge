import Foundation

/// Persistance des métadonnées de reprise : un fichier JSON par transfert
/// interrompu, à côté du `.partial` correspondant.
///
/// Actor : l'accès disque ne doit pas bloquer le fil principal, et une
/// instance par transfert évite tout croisement d'identifiants.
actor ResumePersistence {

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Dossier des métadonnées de reprise, créé au besoin.
    ///
    /// Application Support plutôt qu'un chemin temporaire : les
    /// métadonnées doivent survivre au redémarrage de l'app.
    static func directory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("AirBridge", isDirectory: true)
            .appendingPathComponent("ResumableTransfers", isDirectory: true)
    }

    static func fileURL(for transferID: UUID) -> URL {
        directory()
            .appendingPathComponent("\(transferID.uuidString).json")
    }

    static func makePersistence(transferID: UUID) -> ResumePersistence {
        ResumePersistence(url: fileURL(for: transferID))
    }

    func save(_ info: ResumeTransferInfo) throws {
        let directory = url.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let data = try JSONEncoder().encode(info)
        try data.write(to: url, options: .atomic)
    }

    func load() throws -> ResumeTransferInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ResumeTransferInfo.self, from: data)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }
}
