//
//  TransferPerformanceLog.swift
//  AirBridge
//

import Foundation

/// Instrumentation de débit, activable par un seul drapeau.
///
/// Comparer NORMAL (premier envoi) et RESUME (après reprise) :
/// taille de chunk, chunks simultanés max, chunks/s, temps moyen d'envoi,
/// temps de lecture disque, temps d'encodage. Chaque ligne agrégée permet
/// de localiser où le débit se perd sans noyer la console.
enum TransferPerformanceLog {

    /// Passer à `true` pour activer les mesures (aucun coût sinon).
    static let isEnabled = false

    /// Fenêtre d'agrégation : une ligne est émise toutes les N chunks,
    /// ou à la clôture du transfert (`finish`).
    private static let windowSize = 50

    struct Window {
        var mode: String
        var chunkSize: Int = 0
        var chunkCount = 0
        var bytes: Int64 = 0
        var maxInFlight = 0
        var sendTotal = 0.0
        var readTotal = 0.0
        var encodeTotal = 0.0
        var receiveTotal = 0.0
        var decryptTotal = 0.0
        var writeTotal = 0.0
        var maxInFlightReceive = 0
        var startedAt = Date()
    }

    private static var windows: [UUID: Window] = [:]
    private static let lock = NSLock()

    /// Débute (ou réinitialise) une fenêtre de mesure pour un transfert.
    static func begin(transferID: UUID, mode: String, chunkSize: Int) {
        guard isEnabled else { return }
        lock.withLock {
            windows[transferID] = Window(mode: mode, chunkSize: chunkSize)
        }
        print("📊 [PERF] \(mode) début — chunk=\(chunkSize / 1024) Kio (\(transferID))")
    }

    /// Enregistre l'envoi d'un chunk avec ses temps partiels (secondes).
    /// Appelé depuis la complétion réseau : le temps de lecture disque est
    /// fourni par le chemin appelant (`AirBridgeCore`).
    static func recordSend(
        transferID: UUID,
        bytes: Int64,
        encodeTime: Double,
        sendTime: Double
    ) {
        record(
            transferID: transferID,
            bytes: bytes,
            inFlight: 0,
            readTime: 0,
            encodeTime: encodeTime,
            sendTime: sendTime
        )
    }

    /// Enregistre la réception d'un chunk avec ses temps partiels (secondes).
    /// Symétrique à `recordSend` : trace le temps de déchiffrement (decrypt),
    /// le temps d'écriture disque (write), et le nombre de chunks en vol
    /// (`inFlight`) pour mesurer la fenêtre réelle côté réception.
    static func recordReceive(
        transferID: UUID,
        bytes: Int64,
        decryptTime: Double,
        writeTime: Double,
        inFlight: Int
    ) {
        guard isEnabled else { return }
        lock.withLock {
            guard var window = windows[transferID] else { return }
            window.chunkCount += 1
            window.bytes += bytes
            if inFlight > 0 {
                window.maxInFlightReceive = max(window.maxInFlightReceive, inFlight)
            }
            window.decryptTotal += decryptTime
            window.writeTotal += writeTime
            window.receiveTotal += decryptTime + writeTime
            windows[transferID] = window

            if window.chunkCount % windowSize == 0 {
                emitReceive(window, transferID: transferID)
            }
        }
    }

    /// Enregistre l'envoi d'un chunk avec ses temps partiels (secondes).
    static func record(
        transferID: UUID,
        bytes: Int64,
        inFlight: Int,
        readTime: Double,
        encodeTime: Double,
        sendTime: Double
    ) {
        guard isEnabled else { return }
        lock.withLock {
            guard var window = windows[transferID] else { return }
            window.chunkCount += 1
            window.bytes += bytes
            if inFlight > 0 {
                window.maxInFlight = max(window.maxInFlight, inFlight)
            }
            window.readTotal += readTime
            window.encodeTotal += encodeTime
            window.sendTotal += sendTime
            windows[transferID] = window

            if window.chunkCount % windowSize == 0 {
                emit(window, transferID: transferID)
            }
        }
    }

    /// Émet la dernière fenêtre et ferme la mesure du transfert.
    static func finish(transferID: UUID) {
        guard isEnabled else { return }
        lock.withLock {
            guard let window = windows.removeValue(forKey: transferID) else {
                return
            }
            emit(window, transferID: transferID)
        }
    }

    /// Doit être appelé sous verrou.
    private static func emit(_ window: Window, transferID: UUID) {
        let elapsed = Date().timeIntervalSince(window.startedAt)
        let mbPerSecond = elapsed > 0
            ? Double(window.bytes) / 1_048_576 / elapsed
            : 0
        let perChunk = window.chunkCount > 0
            ? window.sendTotal / Double(window.chunkCount)
            : 0
        let chunksPerSecond = elapsed > 0
            ? Double(window.chunkCount) / elapsed
            : 0

        print(
            "📊 [PERF] \(window.mode) — "
            + "chunk=\(window.chunkSize / 1024) Kio "
            + "n=\(window.chunkCount) "
            + "\(String(format: "%.1f", mbPerSecond)) Mio/s "
            + "(\(String(format: "%.1f", chunksPerSecond)) chunks/s) "
            + "maxEnVol=\(window.maxInFlight) "
            + "lecture=\(String(format: "%.3f", window.readTotal)) s "
            + "encodage=\(String(format: "%.3f", window.encodeTotal)) s "
            + "envoiMoyen=\(String(format: "%.1f", perChunk * 1000)) ms"
        )
    }

    /// Variante RECEIVE de `emit`. Symétrique : même ligne de
    /// rapport, mais avec les temps de déchiffrement et d'écriture
    /// disque + la fenêtre en vol mesurée côté réception.
    /// Doit être appelé sous verrou.
    private static func emitReceive(_ window: Window, transferID: UUID) {
        let elapsed = Date().timeIntervalSince(window.startedAt)
        let mbPerSecond = elapsed > 0
            ? Double(window.bytes) / 1_048_576 / elapsed
            : 0
        let perChunk = window.chunkCount > 0
            ? window.receiveTotal / Double(window.chunkCount)
            : 0
        let chunksPerSecond = elapsed > 0
            ? Double(window.chunkCount) / elapsed
            : 0

        print(
            "📊 [PERF] \(window.mode) — "
            + "chunk=\(window.chunkSize / 1024) Kio "
            + "n=\(window.chunkCount) "
            + "\(String(format: "%.1f", mbPerSecond)) Mio/s "
            + "(\(String(format: "%.1f", chunksPerSecond)) chunks/s) "
            + "maxEnVol=\(window.maxInFlightReceive) "
            + "dechiffrement=\(String(format: "%.3f", window.decryptTotal)) s "
            + "ecriture=\(String(format: "%.3f", window.writeTotal)) s "
            + "receptionMoyenne=\(String(format: "%.1f", perChunk * 1000)) ms"
        )
    }
}
