//
//  ShareDropHandlerTests.swift
//  AirBridgeTests
//
//  Tests unitaires de `ShareDropHandler.loadFileURLs(from:)`.
//
//  Stratégie de mock de `NSItemProvider` :
//  --------------------------------------
//  `NSItemProvider` est une classe Foundation dont l'API de
//  chargement repose sur des blocs `NSItemProviderLoadHandler` /
//  `NSItemProviderCompletionHandler` annotés `NS_SWIFT_SENDABLE`
//  côté header Objective-C. Tenter d'overrider
//  `loadItem(forTypeIdentifier:options:completionHandler:)` en
//  Swift fait crasher le type-checker (cf. SR-15921) ou
//  corrompt la convention d'appel Objective-C au runtime
//  (le `unsafeBitCast` du handler `@Sendable` casse le
//  `NSInvocation` sous-jacent quand le payload est un
//  `NSSecureCoding` comme `Data`).
//
//  On utilise donc l'API publique d'enregistrement :
//    `NSItemProvider()` + `registerItemForTypeIdentifier:
//     loadHandler:` qui passent par le chemin
//  Foundation, sans aucun override. C'est plus verbeux mais
//  c'est le seul chemin qui survit au type-checker Swift 5.10
//  + Xcode 26.5 (et qui ne corrompt pas les blocs `@Sendable`
//  quand le payload est `Data`).
//
//  Couverture :
//    - Liste vide → [].
//    - Providers non `fileURL` → ignorés.
//    - Provider `fileURL` valide → URL présente.
//    - Providers multiples valides → ordre préservé.
//    - Provider qui livre `nil` → ignoré.
//    - Provider qui livre autre chose que `Data` → ignoré.
//    - Mix de providers valides/invalides → seuls les fileURL
//      valides sont conservés, dans l'ordre.
//
//  Couvre la Phase 5 (drop-and-drop global macOS / iOS) —
//  extraction de la logique de conversion `NSItemProvider` → `[URL]`.
//

import XCTest
import UniformTypeIdentifiers
@testable import AirBridge

final class ShareDropHandlerTests: XCTestCase {

    // MARK: - Helpers

    /// Construit une `URL` fichier réelle sur disque (le helper
    /// d'origine de `ShareDropHandler` s'attend à reconstruire
    /// l'URL via `URL(dataRepresentation:)`, qui produit une
    /// `fileURL` valide quand la data encode un chemin absolu).
    private func makeTempFileURL(name: String = "drop.txt") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("payload".utf8)
        )
        return url
    }

    /// Construit un provider qui se déclare conforme à
    /// `public.file-url` et livre, à l'appel de `loadItem`, la
    /// `Data` de l'URL (le format attendu par
    /// `URL(dataRepresentation:relativeTo:)`).
    private func makeFileURLProvider(url: URL) -> NSItemProvider {
        let data = url.dataRepresentation
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { completion, _, _ in
            // `completion` est `NSItemProvider.CompletionHandler?`
            // — il faut l'unwrap avant d'invoquer.
            // On caste `Data` en `NSData` (qui est `NSSecureCoding`
            // côté Objective-C) pour satisfaire la signature de
            // la completion.
            let payload: NSSecureCoding = data as NSData
            completion?(payload, nil)
        }
        return provider
    }

    /// Construit un provider qui se déclare conforme à
    /// `public.text` (donc PAS à `public.file-url`) et livre une
    /// chaîne à l'appel de `loadItem`. Sert à vérifier le rejet
    /// des providers non-fichier.
    private func makeTextProvider(text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.text.identifier
        ) { completion, _, _ in
            let payload: NSSecureCoding = text as NSString
            completion?(payload, nil)
        }
        return provider
    }

    /// Construit un provider qui livre `nil` à l'appel de
    /// `loadItem` (échec silencieux de chargement).
    private func makeNilPayloadProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { completion, _, _ in
            completion?(nil, nil)
        }
        return provider
    }

    /// Construit un provider conforme à `public.file-url` mais qui
    /// livre un type non-`Data` (un `NSString` ici) à `loadItem`.
    private func makeWrongTypeProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { completion, _, _ in
            let payload: NSSecureCoding = "not a data" as NSString
            completion?(payload, nil)
        }
        return provider
    }

    // MARK: - Tests

    func testEmptyListReturnsEmpty() async {
        let urls = await ShareDropHandler.loadFileURLs(from: [])
        XCTAssertEqual(
            urls.count,
            0,
            "Une liste de providers vide doit produire []."
        )
    }

    func testNonFileURLProvidersAreIgnored() async {
        let providers = [
            makeTextProvider(text: "hello"),
            makeTextProvider(text: "world"),
        ]
        let urls = await ShareDropHandler.loadFileURLs(from: providers)
        XCTAssertEqual(
            urls.count,
            0,
            "Les providers conformes à autre chose que fileURL doivent être rejetés."
        )
    }

    func testValidFileURLProviderYieldsURL() async {
        let fileURL = makeTempFileURL(name: "one.txt")
        let provider = makeFileURLProvider(url: fileURL)

        let urls = await ShareDropHandler.loadFileURLs(from: [provider])

        XCTAssertEqual(
            urls.count,
            1,
            "Un provider fileURL valide doit produire exactement une URL."
        )
        XCTAssertEqual(
            urls.first?.path,
            fileURL.path,
            "L'URL reconstruite doit pointer sur le fichier original."
        )
        XCTAssertTrue(
            urls.first?.isFileURL ?? false,
            "L'URL reconstruite doit être une fileURL."
        )
    }

    func testMultipleValidProvidersPreserveOrder() async {
        let a = makeTempFileURL(name: "a.txt")
        let b = makeTempFileURL(name: "b.txt")
        let c = makeTempFileURL(name: "c.txt")

        let providers = [
            makeFileURLProvider(url: a),
            makeFileURLProvider(url: b),
            makeFileURLProvider(url: c),
        ]

        let urls = await ShareDropHandler.loadFileURLs(from: providers)

        XCTAssertEqual(
            urls.count,
            3,
            "Trois providers valides doivent produire trois URLs."
        )
        XCTAssertEqual(
            urls.map { $0.path },
            [a.path, b.path, c.path],
            "L'ordre d'arrivée des providers doit être préservé dans le résultat."
        )
    }

    func testNilPayloadIsIgnored() async {
        // Un provider qui se déclare fileURL mais livre nil : le
        // helper doit le filtrer sans crasher.
        let provider = makeNilPayloadProvider()
        let urls = await ShareDropHandler.loadFileURLs(from: [provider])
        XCTAssertEqual(
            urls.count,
            0,
            "Un provider qui livre nil doit produire une liste vide."
        )
    }

    func testNonDataPayloadIsIgnored() async {
        // Un provider qui livre autre chose que Data (un NSString
        // ici) ne doit pas non plus polluer la sortie.
        let provider = makeWrongTypeProvider()
        let urls = await ShareDropHandler.loadFileURLs(from: [provider])
        XCTAssertEqual(
            urls.count,
            0,
            "Un provider qui livre autre chose que Data doit être ignoré."
        )
    }

    func testMixedProvidersOnlyFileURLsAreKept() async {
        // Cas d'intégration : un mix de providers valides et
        // invalides ne doit laisser passer que les fileURL.
        let a = makeTempFileURL(name: "a.txt")
        let c = makeTempFileURL(name: "c.txt")

        let providers: [NSItemProvider] = [
            makeFileURLProvider(url: a),
            makeTextProvider(text: "ignored"),
            makeNilPayloadProvider(),
            makeFileURLProvider(url: c),
            makeWrongTypeProvider(),
        ]

        let urls = await ShareDropHandler.loadFileURLs(from: providers)

        XCTAssertEqual(
            urls.count,
            2,
            "Seuls les providers fileURL qui livrent une Data valide doivent passer."
        )
        XCTAssertEqual(
            urls.map { $0.path },
            [a.path, c.path],
            "L'ordre des providers valides doit être préservé."
        )
    }
}
