import Foundation

/// Métadonnées persistées d'un transfert interrompu, suffisantes pour
/// proposer une reprise après redémarrage ou reconnexion du pair.
///
/// Isolation : ce type est manipulé depuis le `ResumePersistence` (actor
/// hors MainActor) comme depuis les classes `@MainActor` du cœur. Le
/// projet compile avec `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, qui
/// isolerait sinon implicitement ses conformances `Codable` au fil
/// principal — et rendrait `JSONEncoder`/`JSONDecoder` inutilisables
/// depuis l'actor. `nonisolated` rend l'isolation explicite et neutre :
/// la structure est une simple valeur `Sendable`, sans état mutable.
nonisolated struct ResumeTransferInfo: Codable, Sendable {
    let transferID: UUID
    let fileSize: Int64
    let transferredBytes: Int64
    let fileName: String
    let direction: String
    let peerID: UUID
    let timestamp: Date
    let partialFileURL: URL

    /// Nom affichable du pair au moment de l'interruption.
    ///
    /// Optionnel : absent des métadonnées écrites avant son introduction,
    /// et un nom manquant ne doit jamais invalider une reprise valide.
    var peerName: String?

    /// URL de la source côté émetteur (copie locale protégant l'original).
    ///
    /// Optionnel pour la même raison de compatibilité ; côté réception il
    /// reste `nil`, le `.partial` portant déjà les octets reçus.
    var sourceFileURL: URL?

    /// Empreinte SHA-256 calculée sur la source complète au premier envoi.
    ///
    /// Vide tant que l'émetteur ne l'a pas (calculée à la préparation) ;
    /// elle accompagne la demande de reprise pour que le récepteur puisse
    /// vérifier qu'il reprend le même fichier.
    var sha256: String?

    /// Version du protocole négociée au moment de l'interruption.
    ///
    /// Optionnel : les métadonnées antérieures n'en disposaient pas, et le
    /// défaut `ProtocolCompatibility.currentVersion` reste sûr (la
    /// négociation repart de zéro à chaque nouvelle session).
    var protocolVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case transferID
        case fileSize
        case transferredBytes
        case fileName
        case direction
        case peerID
        case timestamp
        case partialFileURL
        case peerName
        case sourceFileURL
        case sha256
        case protocolVersion
    }

    init(
        transferID: UUID,
        fileSize: Int64,
        transferredBytes: Int64,
        fileName: String,
        direction: String,
        peerID: UUID,
        timestamp: Date,
        partialFileURL: URL,
        peerName: String? = nil,
        sourceFileURL: URL? = nil,
        sha256: String? = nil,
        protocolVersion: Int? = nil
    ) {
        self.transferID = transferID
        self.fileSize = fileSize
        self.transferredBytes = transferredBytes
        self.fileName = fileName
        self.direction = direction
        self.peerID = peerID
        self.timestamp = timestamp
        self.partialFileURL = partialFileURL
        self.peerName = peerName
        self.sourceFileURL = sourceFileURL
        self.sha256 = sha256
        self.protocolVersion = protocolVersion
    }

    /// Décodage tolérant : un champ ajouté après coup, absent d'un ancien
    /// JSON, vaut `nil` plutôt qu'une erreur de décodage qui perdrait une
    /// reprise pourtant valide.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        transferID = try container.decode(UUID.self, forKey: .transferID)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        transferredBytes = try container.decode(
            Int64.self,
            forKey: .transferredBytes
        )
        fileName = try container.decode(String.self, forKey: .fileName)
        direction = try container.decode(String.self, forKey: .direction)
        peerID = try container.decode(UUID.self, forKey: .peerID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        partialFileURL = try container.decode(URL.self, forKey: .partialFileURL)

        peerName = try container.decodeIfPresent(
            String.self,
            forKey: .peerName
        )
        sourceFileURL = try container.decodeIfPresent(
            URL.self,
            forKey: .sourceFileURL
        )
        sha256 = try container.decodeIfPresent(
            String.self,
            forKey: .sha256
        )
        protocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .protocolVersion
        )
    }

    /// Version du protocole à utiliser pour une reprise : celle négociée à
    /// l'interruption si connue, sinon la version courante.
    var effectiveProtocolVersion: Int {
        protocolVersion ?? ProtocolCompatibility.currentVersion
    }

    /// Corrige les métadonnées avec la taille réellement présente sur le
    /// disque : un fichier partiel tronqué fait foi à la baisse, jamais à
    /// la hausse (des octets au-delà des métadonnées seraient invérifiables).
    static func reconciledTransferredBytes(
        metadataBytes: Int64,
        onDiskBytes: Int64
    ) -> Int64 {
        min(max(onDiskBytes, 0), max(metadataBytes, 0))
    }
}
