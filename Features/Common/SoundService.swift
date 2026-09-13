//
//  SoundService.swift
//  AirBridge
//
//  Wrapper minimaliste autour de `AudioServicesPlaySystemSound` pour
//  émettre un feedback audio court (son système iOS/macOS) lors
//  d'événements de connexion.
//
//  Pourquoi `AudioServicesPlaySystemSound` plutôt qu'un bundle audio
//  custom ou `AVAudioPlayer` ?
//
//  - Son système natif iOS/macOS : pas de fichier audio à packager
//    ni à versionner, pas de risque de chargement asynchrone raté.
//  - Latence < 50 ms entre l'appel et la sortie son, suffisant pour
//    un feedback de connexion qui doit rester discret et immédiat.
//  - L'appel est joué en parallèle d'autres sons système (autres
//    apps, alertes OS) et ne bloque pas le thread appelant : le
//    framework `AudioToolbox` rend la main immédiatement.
//  - Aucune permission requise : `AudioToolbox` est exempté du
//    consentement microphone.
//
//  Cette abstraction suit la même philosophie que `Haptics` : un
//  namespace statique, idempotent, et appelable depuis n'importe quel
//  contexte (Views, ConnectionManager, etc.) sans avoir à gérer un
//  cycle de vie d'instance.
//
//  Le `SystemSoundID` 1057 ("Tink") est l'identifiant du son système
//  iOS historique joué pour confirmer une action réussie. Il est
//  disponible identiquement sur iOS et macOS (catalogue partagé via
//  `AudioToolbox`), donc aucun `#if os(iOS)` n'est nécessaire autour
//  du `rawValue`. L'appel lui-même est gardé par
//  `#if canImport(AudioToolbox)` pour permettre la compilation sur
//  des cibles exotiques (CI Linux hypothétique) où le framework ne
//  serait pas disponible — dans ce cas, l'API devient un no-op
//  silencieux plutôt que de faire échouer le build.
//

import Foundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Surface de feedback audio du module Connexion.
///
/// Toutes les méthodes sont idempotentes : appeler `play(.connected)`
/// plusieurs fois d'affilée ne provoque ni crash ni effet secondaire
/// observable au-delà de la répétition du son. C'est volontaire, car
/// le `stateUpdateHandler` de `NWConnection` peut être ré-entré dans
/// certains cas transitoires ; on préfère un double ping audible à
/// un crash ou à un lock.
enum SoundService {

    /// Événements sonores actuellement exposés.
    ///
    /// L'enum est volontairement minimaliste : on n'ajoute un cas que
    /// lorsqu'un événement UX clair le justifie. Les retours haptiques
    /// `success` / `warning` / `error` restent gérés par `Haptics` —
    /// audio et haptique sont deux canaux sensoriels distincts et
    /// complémentaires, pas des doublons.
    enum SoundEvent {
        /// Connexion sécurisée `.ready` établie avec un pair distant.
        /// Joué une seule fois par transition réussie grâce au guard
        /// `isSessionReady` déjà présent dans `ConnectionManager`.
        case connected

        /// Identifiant `SystemSoundID` correspondant à l'événement.
        /// 1057 = "Tink" (son système positif court).
        var rawValue: SystemSoundID {
            // Cross-platform iOS / macOS : le catalogue `AudioToolbox`
            // partage les mêmes `SystemSoundID` historiques sur les
            // deux plateformes depuis iOS 2 / Mac OS X 10.5.
            switch self {
            case .connected:
                return 1057
            }
        }
    }

    // MARK: - Public API

    /// Joue le son système associé à l'événement.
    ///
    /// - Parameter event: événement UX à signaler.
    ///
    /// L'appel ne lève pas, ne retourne rien, et reste thread-safe :
    /// `AudioServicesPlaySystemSound` peut être appelé depuis
    /// n'importe quelle file. Pas besoin de `@MainActor` malgré
    /// l'usage depuis la branche `case .ready` du `ConnectionManager`
    /// (qui est déjà sur le main thread).
    static func play(_ event: SoundEvent) {
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(event.rawValue)
        #endif
    }
}
