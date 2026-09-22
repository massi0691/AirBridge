//
//  FileHasher.swift
//  AirBridge
//
//  Created by massi9106 on 02/08/2026.
//



import CryptoKit
import Foundation

enum FileHasherError: Error {
    case unableToOpenFile
}

struct FileHasher {

    static func sha256(of fileURL: URL) throws -> String {
        guard let stream = InputStream(url: fileURL) else {
            throw FileHasherError.unableToOpenFile
        }

        stream.open()

        // Un fichier absent ou illisible positionne `streamError` dès
        // l'ouverture, MAIS laisse `hasBytesAvailable` à faux : sans cette
        // vérification, la boucle ci-dessous serait sautée et l'empreinte
        // renvoyée serait celle du vide — un fichier manquant serait
        // silencieusement confondu avec un fichier vide.
        if let streamError = stream.streamError {
            throw streamError
        }

        defer {
            stream.close()
        }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](
            repeating: 0,
            count: bufferSize
        )

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(
                &buffer,
                maxLength: buffer.count
            )

            if bytesRead < 0 {
                throw stream.streamError
                    ?? FileHasherError.unableToOpenFile
            }

            if bytesRead == 0 {
                break
            }

            hasher.update(
                data: Data(buffer[0..<bytesRead])
            )
        }

        return hasher.finalize()
            .map {
                String(format: "%02x", $0)
            }
            .joined()
    }

    /// Empreinte ou `nil` si le fichier est illisible : variante non
    /// levante pour les chemins de reprise, où un SHA indisponible ne doit
    /// jamais invalider des métadonnées par ailleurs valides.
    static func sha256IfAvailable(of fileURL: URL) -> String? {
        try? sha256(of: fileURL)
    }
}
