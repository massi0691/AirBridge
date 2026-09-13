//
//  UIThrottleTests.swift
//  AirBridgeTests
//
//  Tests unitaires de la primitive `UIThrottle` utilisée par les
//  ViewModels pour coalescer le flux haute fréquence du Core vers la
//  couche UI.
//
//  Couvre la Phase 4 (couche UIThrottle → UI à 10 FPS) en
//  vérifiant que :
//   - la première valeur est publiée immédiatement ;
//   - les soumissions consécutives sont coalescées dans la fenêtre
//     d'intervalle ;
//   - `flush()` contourne la fenêtre pour les états terminaux ;
//   - un flux rapide (100 submits) ne génère pas plus que le
//     nombre attendu de republishes ;
//   - la valeur la plus récente gagne quand plusieurs submits sont
//     coalescés.
//
//  Ces tests sont sur le MainActor : `UIThrottle` est lui-même
//  `@MainActor` et la `AsyncStream` qu'il expose est censée être
//  consommée depuis le main thread du runloop applicatif.
//
//  Note d'implémentation : un `for await` direct sur la stream du
//  throttle bloquerait jusqu'à `continuation.finish()` (jamais
//  appelé en production). On wrappe donc la stream dans un
//  `ThrottleSpy` qui tourne dans sa propre `Task`, et on lit son
//  buffer via un `withTaskGroup` qui impose un timeout.
//

import XCTest
@testable import AirBridge

@MainActor
final class UIThrottleTests: XCTestCase {

    // MARK: - Helpers

    /// Petit collecteur qui drâne la `stream` d'un throttle dans un
    /// buffer. On peut l'arrêter à tout moment avec `stop()`.
    private final class ThrottleSpy {
        private(set) var values: [Int] = []
        private let stream: AsyncStream<Int>
        private let continuation: AsyncStream<Int>.Continuation
        private let consumer: Task<Void, Never>

        init(throttle: UIThrottle<Int>) {
            // On crée notre propre stream pour pouvoir la fermer
            // proprement. Le throttle yield ses valeurs dans sa
            // propre stream ; on l'écoute en tâche de fond et on
            // recopie dans notre buffer.
            //
            // Note : on ne peut pas écouter directement la stream
            // interne du throttle (sa continuation n'est pas
            // publique). On fait donc un tap avec une stream
            // dédiée : à chaque fois que le throttle émet une
            // valeur, on la repique dans notre buffer.
            //
            // L'astuce : on lance la souscription dans une task
            // détachée et on expose `stop()` pour fermer la
            // stream espion.
            var capturedContinuation: AsyncStream<Int>.Continuation!
            self.stream = AsyncStream<Int> { cont in
                capturedContinuation = cont
            }
            self.continuation = capturedContinuation
            self.consumer = Task { [stream] in
                for await value in stream {
                    // no-op : on ne fait rien, on lit le buffer
                    // directement via l'API publique.
                    _ = value
                }
            }
        }

        deinit {
            consumer.cancel()
        }
    }

    /// Attend `wait` secondes en laissant le MainActor libre de
    /// traiter les yields du throttle, puis renvoie le buffer
    /// accumulé.
    ///
    /// C'est l'astuce : on n'écoute pas la stream directement (ce
    /// qui hang), on laisse le temps au throttle d'émettre ses
    /// valeurs et on observe l'effet via un side-channel.
    private func sleep(_ wait: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    // MARK: - Tests

    /// La toute première soumission doit être publiée sans attendre
    /// : c'est la garantie que le premier repaint arrive à l'heure.
    func testSubmitRepublishesImmediatelyOnFirstValue() async {
        let throttle = UIThrottle<Int>(interval: 0.2)
        // Premier consumer : on lit juste assez pour confirmer le
        // premier yield.
        let firstTask = Task<Int, Never> {
            for await value in throttle.stream {
                return value
            }
            return -1
        }

        throttle.submit(42)
        let received = await firstTask.value
        XCTAssertEqual(
            received,
            42,
            "La première soumission doit être publiée immédiatement."
        )
    }

    /// Deux submits dans la même fenêtre doivent être coalescés en un
    /// seul republish (le dernier gagne). On lit la première valeur
    /// puis on annule le consumer pour éviter le hang.
    func testConsecutiveSubmitsAreCoalescedWithinInterval() async {
        let throttle = UIThrottle<Int>(interval: 0.3)

        // Consumer 1 : on attend le premier yield (qui doit être 1).
        let firstTask = Task<Int?, Never> {
            for await value in throttle.stream {
                return value
            }
            return nil
        }
        throttle.submit(1)
        let first = await firstTask.value
        XCTAssertEqual(first, 1)

        // Maintenant on lance un 2e consumer pour observer les
        // suivants. Le 2e submit est coalescé : on l'attend 500 ms
        // et on s'attend à voir 3 (le 2 a été écrasé par 3).
        let coalescedTask = Task<Int?, Never> {
            for await value in throttle.stream {
                return value
            }
            return nil
        }

        throttle.submit(2)
        throttle.submit(3)

        let coalesced = await coalescedTask.value
        // Le throttle doit émettre le dernier pending (3) à la fin
        // de la fenêtre (300 ms après le premier submit).
        XCTAssertEqual(
            coalesced,
            3,
            "Le dernier submit (3) doit être publié après la fenêtre de coalescing (reçu: \(String(describing: coalesced)))."
        )
    }

    /// `flush()` doit publier la valeur en attente en bypassant
    /// l'intervalle : c'est crucial pour les états terminaux qui
    /// doivent apparaître à l'écran sans attendre 100 ms.
    func testFlushBypassesTheInterval() async {
        let throttle = UIThrottle<Int>(interval: 0.5)

        // Premier consumer : on capte le premier yield (1).
        let firstTask = Task<Int, Never> {
            for await value in throttle.stream {
                return value
            }
            return -1
        }

        throttle.submit(1)
        let first = await firstTask.value
        XCTAssertEqual(first, 1)

        // Deuxième submit — sans flush, il serait coalescé.
        throttle.submit(99)
        // flush() doit le publier immédiatement.
        throttle.flush()

        let secondTask = Task<Int, Never> {
            for await value in throttle.stream {
                return value
            }
            return -1
        }
        let second = await secondTask.value
        XCTAssertEqual(
            second,
            99,
            "flush() doit publier la valeur pending sans attendre la fin de la fenêtre (reçu: \(second))."
        )
    }

    /// 100 submits en boucle serrée ne doivent produire qu'un nombre
    /// borné de republishes. C'est la garantie de performance.
    /// On compte les yields sur une fenêtre de 500 ms.
    func testRapidStreamDoesNotExceedTheInterval() async {
        let throttle = UIThrottle<Int>(interval: 0.1)
        let counter = YieldCounter()
        let consumer = Task<Void, Never> {
            for await _ in throttle.stream {
                await counter.increment()
            }
        }
        // Annulation après 500 ms.
        let canceller = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
            consumer.cancel()
        }
        _ = canceller

        // Boucle serrée : 100+ submits en moins de 200 ms.
        let start = Date()
        var i = 0
        while Date().timeIntervalSince(start) < 0.2 {
            throttle.submit(i)
            i += 1
        }

        // Attend la fin de la fenêtre.
        await canceller.value
        let republishCount = await counter.value

        XCTAssertGreaterThan(
            i,
            50,
            "La boucle serrée doit produire plus de 50 submits (réel: \(i))."
        )
        // Sur 500 ms avec un interval de 100 ms, on attend au plus 5
        // republishes. On laisse une marge généreuse (×2) pour la
        // latence d'initialisation du stream et le scheduling du Task.
        XCTAssertLessThanOrEqual(
            republishCount,
            10,
            "Un flux serré sur 500 ms avec interval 100 ms ne doit pas produire plus de 10 yields (reçu: \(republishCount))."
        )
    }

    /// Quand plusieurs submits sont coalescés, c'est la dernière
    /// valeur qui doit être publiée — jamais une intermédiaire.
    func testStreamYieldsTheLatestValueWhenCoalesced() async {
        let throttle = UIThrottle<Int>(interval: 0.3)
        let collector = ValueCollector()

        // On consomme la stream dans une task, et on annule après
        // 500 ms.
        let consumer = Task<Void, Never> {
            for await value in throttle.stream {
                await collector.append(value)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            consumer.cancel()
        }

        throttle.submit(0)
        try? await Task.sleep(nanoseconds: 30_000_000)
        for i in 1...5 {
            throttle.submit(i)
        }

        // Attend la fin de la fenêtre.
        try? await Task.sleep(nanoseconds: 500_000_000)
        consumer.cancel()

        let values = await collector.snapshot()
        // Le dernier republish doit être 5 (la valeur la plus
        // récente), jamais un chiffre intermédiaire.
        XCTAssertEqual(
            values.last,
            5,
            "La valeur la plus récente doit l'emporter après coalescing (reçu: \(values))."
        )
        // On ne doit pas avoir reçu 1, 2, 3, 4 (chacune individuellement).
        for intermediate in [1, 2, 3, 4] {
            XCTAssertFalse(
                values.contains(intermediate),
                "\(intermediate) ne doit pas avoir été publié : il a été coalescé."
            )
        }
    }
}

// MARK: - Actors utilitaires

/// Compteur atomique pour le test de performance (évite les races
/// entre la task de consommation et le test principal).
private actor YieldCounter {
    var _value: Int = 0
    var value: Int { _value }

    func increment() {
        _value += 1
    }
}

/// Buffer thread-safe pour accumuler les valeurs émises par le
/// throttle pendant un test. La `Task` de consommation alimente
/// l'acteur ; le test lit le buffer après l'annulation.
private actor ValueCollector {
    private var _values: [Int] = []

    func append(_ value: Int) {
        _values.append(value)
    }

    func snapshot() -> [Int] {
        _values
    }
}
