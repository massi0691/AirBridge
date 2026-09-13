import Foundation
import Observation

@MainActor
@Observable
final class TransferHistoryStore {

    private(set) var entries: [TransferHistoryEntry] = []
    private let fileURL: URL
    private let maxEntries = 100

    init() {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        self.fileURL = docs.appendingPathComponent("transfer_history.json")
        load()
    }

    func addEntry(_ entry: TransferHistoryEntry) {
        entries.append(entry)
        // Trier par date décroissante (plus récent en premier) puis garder max
        entries.sort { $0.startDate > $1.startDate }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func filteredEntries(
        direction: TransferDirection?,
        status: TransferStatus?
    ) -> [TransferHistoryEntry] {
        var result = entries
        if let direction {
            result = result.filter { $0.direction == direction }
        }
        if let status {
            result = result.filter { $0.status == status }
        }
        return result.sorted { $0.startDate > $1.startDate }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode(
                [TransferHistoryEntry].self,
                from: data
            )
        } catch {
            print("❌ Erreur chargement historique : \(error)")
            entries = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("❌ Erreur sauvegarde historique : \(error)")
        }
    }
}
