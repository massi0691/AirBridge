# 🔎 AIRBRIDGE — AUDIT COMPLET + ROADMAP VERS UNE EXPÉRIENCE TYPE AIRDROP

**Date** : 2026-09-05
**Périmètre** : projet complet (UI / Core / Security / Network / Transfer / Discovery / Notifications / Tests)
**Mode** : ⚠️ **LECTURE SEULE — AUCUNE modification de code effectuée**
**Verdict global** : 🟡 **FONDATIONS SOLIDES — MANQUE LE « MOMENT AIRDROP » EN SURFACE**

---

## 0. Avertissement

Ce rapport est **lecture seule** par contrat. Aucun fichier n'a été modifié. Les recommandations sont formulées en respectant strictement :
- **Préservation** de l'identité longue durée (P-256 Keychain), ECDH éphémère, signatures, trust state, anti-replay, validation des messages, sécurité des sessions, compatibilité protocolaire.
- **Aucune** suggestion de supprimer une protection pour simplifier l'UX.
- Les phases de roadmap sont ordonnées du plus petit risque au plus grand, en gardant la sécurité intacte à chaque palier.

---

## 1. Résumé exécutif

| Catégorie | Verdict | Détail court |
|---|---|---|
| Build (4 configs) | ✅ PASS | 4/4 SUCCEEDED, 0 warning (réf. AUDIT_FINAL 2026-08-31) |
| Tests | ✅ PASS | 419 passed, 2 skipped, 446 s |
| Sécurité crypto | ✅ PASS | P-256 Keychain, ECDH, ChaCha20-Poly1305, anti-replay, TOFU |
| Pairing / Trust | ✅ PASS | keyChangedDowngraded préservé, self-pairing bloqué |
| Architecture | ⚠️ WARNING | `AirBridgeCore.swift` = 3491 l. (god class), `Transfert*` accent manquant |
| Transfer pipeline | ✅ PASS | pipelineDepth=4, ChunkSink actor, MainActor-out complet |
| Reprise après coupure | ✅ PASS | scheduleAutomaticResumeOnReconnect + ResumePersistence actor |
| Notifications | ⚠️ WARNING | Pas de leak PII, 2 `print` "DEBUG:" sans `#if DEBUG` |
| UI / Accessibilité | ⚠️ WARNING | Tokens Design OK, Dynamic Type partiel, Settings en /UI legacy |
| Logs | ❌ FAIL | 327 `print()`, 1 leak SHA-256 (P0) |
| Performance | ✅ PASS | Refactor MainActor-out complet, throttle 10 Hz |
| UX AirDrop | 🟡 MANQUANT | Pas de Share Extension, pas de full-screen radar, pas de preview, pas de code 6 chiffres, pas de contact |
| visionOS | 🟡 NON TESTÉ | Code compile, mais aucune validation UI/vision |

**Conclusion en une phrase** : les fondations cryptographiques, le pipeline, la reprise et les tests sont prêts pour une release candidate ; **l'expérience utilisateur reste un produit « préférences + sélecteur de fichier »** et non un équivalent d'AirDrop — c'est sur ce dernier axe que la roadmap doit se concentrer.

---

## 2. État actuel du projet

### 2.1 Métriques

| Métrique | Valeur | Source |
|---|---|---|
| Fichiers Swift (production) | 96 | `find -name "*.swift" -not -path "*Tests*"` |
| Fichiers Swift (tests) | 44 | `Tests/AirBridgeTests` + `ResumeTests.swift` |
| Lignes de code (prod) | ~21 000 | mesuré |
| Lignes de tests | ~14 300 | mesuré |
| Ratio test/prod | ~0.68 | sain pour une app à risque crypto |
| Cible iOS / macOS | iOS 17+ / macOS 14+ | `Info.plist`, support ContentUnavailableView |
| SDK courant | macOS 26.5 (Xcode 26) | `project.pbxproj` |
| Plateformes | iphoneos, iphonesimulator, macosx, xros, xrsimulator | `project.pbxproj` |
| Bundle ID | `com.airbridge.app` (à vérifier) | `project.pbxproj` |
| Services Bonjour | `_airbridge._tcp`, `includePeerToPeer = true` | `BonjourService.swift`, `Info.plist` |
| Tests passants | 419 / 419 + 2 skipped documentés | exécution 446 s |
| Branches fonctionnelles | Pairing, Transfer, Resume, Notifications, Discovery, Sharing | observées |

### 2.2 Périmètre fonctionnel livré

- Découverte Bonjour pair-à-pair (P2P Wi-Fi + LAN).
- Handshake ECDH P-256 éphémère par session, HKDF-SHA256 (salt = sessionId 16 octets), ChaCha20-Poly1305.
- Authentification P-256 long-terme en Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronisable).
- Signature ECDSA déterministe (JSON canonicalisé `.sortedKeys`, base64).
- Anti-replay (actor, 4096 entrées, TTL 300 s par peer).
- Pairing TOFU à 4 états (`unknown` / `pending` / `trusted` / `blocked`), key-change downgrade `trusted` → `pending`.
- File FIFO sortante strictement sérialisante.
- Pipeline chunks (fenêtre 4, ack pump, désordonnancement corrigé, SHA-256 final).
- Reprise sur coupure (`ResumePersistence` actor, `IncomingFileWriter` tronque si trop long).
- Drag & drop macOS global + iPad (Phase 5).
- Notifications (`UNUserNotificationCenter`, actions Accept / Refuse, `interruptionLevel = .timeSensitive`).
- Haptics multiplateformes (no-op macOS), SoundService minimal.
- Transferts actifs et terminés, swipe-to-cancel, retry sur `interrupted`.
- "Afficher dans le Finder" (macOS) et "Afficher le dossier" (iOS via QLPreviewController).

### 2.3 Limites connues

- **Aucun Share Extension** : impossible d'invoquer AirBridge depuis la feuille de partage système.
- **Aucun Drag & Drop sur l'icône Dock** (macOS).
- **Aucun Live Activity / Dynamic Island** pour les transferts en vol.
- **Aucun background transfer** (`URLSessionConfiguration.background`) — transferts fragiles en arrière-plan.
- **Aucune notification de transfert en arrière-plan** au-delà du système.
- **Aucun preview d'image/vidéo/PDF** dans `TransferRequestSheet` ni `FilePreviewGrid`.
- **Aucun code de vérification à 6 chiffres** à la AirDrop.
- **Aucune intégration Contacts.framework** pour la photo + nom d'utilisateur.
- **Settings encore dans l'ancienne UI** (`/UI/Settings/`) — dette de migration.
- **Pas de "Contacts Only / Everyone / Receiving Off"** global (filtre `showAllRecipients` local au `ShareView`).
- **Pas de "Device Name" éditable** (nom issu de `UIDevice.current.name`).
- **`AirBridgeApp` envoie une notification de test 2 s après chaque lancement** (artefact de dev).
- **Permission de notifications demandée au tout premier lancement**, sans contexte.

---

## 3. Architecture actuelle

### 3.1 Topologie

```
AirBridge/
├── AirBridge/                        # Entry point
│   ├── AirBridgeApp.swift            # 117 l. — @main, CoreHolder, notifications
│   └── Info.plist                    # 14 l. — NSBonjourServices, file sharing
├── Core/                             # Orchestration centrale
│   ├── AirBridgeCore.swift           # 3491 l. — GOD CLASS
│   ├── ResumePersistence.swift       # 71 l. — actor
│   └── ResumeTransferInfo.swift      # 143 l. — Codable
├── Network/
│   └── ConnectionManager.swift       # 1531 l. — TCP + codecs (à découper)
├── Discovery/
│   ├── BonjourService.swift          # NWListener + NWBrowser
│   ├── Device.swift / DiscoveredDevice.swift
│   ├── LocalDeviceFactory.swift
│   └── DiscoveryManager.swift        # STUB VIDE (109 octets, 0 méthode)
├── Security/                         # 1548 l. au total
│   ├── SecureIdentity.swift          # Keychain P-256
│   ├── SecureHandshake.swift         # ECDH éphémère
│   ├── AuthenticationPolicy.swift
│   ├── MessageAuthenticator.swift    # ECDSA, canonicalisation JSON
│   ├── PairingStore.swift            # TOFU + persistence UserDefaults
│   ├── ReplayProtectionStore.swift   # actor, 4096 entrées, TTL 300 s
│   └── ChunkStreamCipher.swift       # ChaCha20-Poly1305
├── Transfer/                         # 5215 l. au total
│   ├── TransferManager.swift         # 884 l. (contient du code mort)
│   ├── IncomingTransferManager.swift # 673 l.
│   ├── OutgoingTransferManager.swift # 493 l.
│   ├── OutgoingTransferQueue.swift   # FIFO
│   ├── OutgoingSelectionPlanner.swift# 311 l.
│   ├── ChunkSink.swift               # actor (421 l.)
│   ├── IncomingFileWriter.swift      # 197 l.
│   ├── FileHasher.swift              # SHA-256 streaming
│   ├── OutgoingFileSource.swift      # 13 l. POD
│   ├── TransferStore.swift           # 223 l. (mémoire)
│   ├── TransferHistoryStore.swift    # 79 l. (JSON disque)
│   ├── PendingApprovalCoordinator.swift
│   ├── PendingTransferRequest.swift
│   ├── ReceivedBatchLayout.swift / ReceivedBatchLimits.swift
│   ├── TransferChunkSizing.swift
│   ├── TransfertStorage.swift        # accent "Transfert" (incohérence)
│   ├── TransfertTimeoutManager.swift # idem
│   ├── NetworkErrorClassifier.swift
│   └── TransferPerformanceLog.swift  # compile-out par défaut
├── Protocol/                         # 7 fichiers (FrameCodec, MessageRouter, etc.)
├── Notifications/
│   └── NotificationManager.swift     # 469 l.
├── Settings/
│   └── ReceivedFolderStore.swift     # security-scoped bookmark
├── Session/
│   └── AirBridgeSession.swift        # 67 l.
├── Design/                           # Design tokens (6 fichiers)
├── UI/                               # LEGACY (Settings, MainView, Components)
└── Features/                         # NOUVELLE UI
    ├── Common/                       # Haptics, SoundService, Transitions, UIThrottle
    ├── Discovery/                    # Radar (6 fichiers)
    ├── Pairing/                      # PairingConfirmationView, PairingDeviceCard
    ├── Sharing/                      # ShareView, ShareDropHandler, RecipientSelector
    └── Transfer/                     # TransferView, FileActionSheet, etc.
```

### 3.2 Couplages observés

- **`AirBridgeCore`** : 12+ collaborateurs directs, 25+ champs `@Observable`, 5 types internes (`PipelineWindow`, `OrderedAckPump`, `PipelineErrorSlot`, `PipelineChunk`).
- **`ConnectionManager`** : 1531 l. propriétaire des `NWConnection`, mais le Core lit `connection.endpoint` à plusieurs endroits (fuite conceptuelle).
- **`PendingTransferBatch`** porte la `NWConnection` — fuite de la couche `Session/` vers `Transfer/`.
- **3 couches pour la session** : `AirBridgeSession` (propre), `session: AirBridgeSession?` dans `ConnectionManager`, `activeSessionId: UUID?` dans `ConnectionManager`, `hasAdoptedSessionIdFromKeyExchange: Bool` dans `AirBridgeCore`.
- **Pas de couche « Use Case »** : pas de `SendFileUseCase`, `ReceiveFileUseCase`, `CancelTransferUseCase`. Tout est méthode de `AirBridgeCore`.
- **Persistance éclatée** entre `UserDefaults` (PairingStore, ReceivedFolderStore, LocalDeviceFactory, Settings), Keychain (SecureIdentity), JSON disque (Resume, History), `.partial` tmp (IncomingFileWriter).

### 3.3 Couplages dans `UI/`

- `SettingsView` lit `PairingStore` directement (fuite conceptuelle P3) au lieu de passer par `PairingViewModel`.
- `DiscoveryView` lit `core.pairingStore.loadAll()` directement.
- `MainView` consomme `core.receivedFolderStore`, `core.notificationManager`, `core.pairingStore` directement (trop de surface Core exposée).
- `ShareView` importe `Network` pour construire un `NWEndpoint` dummy (fuite).

---

## 4. Ce qui fonctionne bien

### 4.1 Sécurité — briques matures
- **P-256 long-terme en Keychain** avec attributs stricts (non-synchronisable, accessible only-when-unlocked).
- **ECDH P-256 éphémère par session** + HKDF-SHA256 (salt = sessionId 16 octets, info = `"airbridge-v2-session"`).
- **ChaCha20-Poly1305** en streaming avec AAD = `transferID ‖ chunkIndex ‖ sessionId`, nonces déterministes.
- **Signatures ECDSA** sur JSON canonicalisé (`.sortedKeys`, base64) — `MessageAuthenticator` nonisolated.
- **`AuthenticationPolicy`** : `.required` pour messages sensibles, `.forbidden` pour `fileChunk` (chaîne protégée par `transferCompleted` signé).
- **Anti-replay** (actor, LRU 4096, TTL 300 s) avec ordre `verify → observe` strict.
- **TOFU** : `keyChangedDowngraded` (`trusted` → `pending` sur changement de clé) préservé.
- **Self-pairing bloqué** par `verifyPairingPayload` (ligne 312) et `verifyIncomingPairingRequest` (ligne 410).
- **Validation TOFU** explicitement documentée, mitigée par affichage d'empreinte (l'utilisateur compare).

### 4.2 Pipeline de transfert — production-ready
- `pipelineDepth = 4`, `uiBatchStride = 8`.
- `ChunkSink` est un `actor` dédié (sérialisation déchiffrement + écriture).
- `IncomingFileWriter` est `nonisolated final class` encapsulé par `ChunkSink` (invariant écrivain unique).
- `OutgoingTransferManager.sendChunkOverConnectionStatic` est `static nonisolated` (chemin chaud hors MainActor).
- Refactor Phase 2-bis complet, 5 sauts MainActor résiduels (P3).
- TCP tuning agressif : `noDelay`, `disableAckStretching`, `enableFastOpen`, `serviceClass = .responsiveData`.

### 4.3 Reprise — robuste
- `scheduleAutomaticResumeOnReconnect` sur `.ready`.
- `endResumeCampaign` sur fermeture de session.
- `ResumePersistence` actor dédié, JSON dans `Application Support/AirBridge/ResumableTransfers/`.
- `IncomingFileWriter` réouvre `.partial` sur la taille disque, tronque si trop long.
- `NetworkErrorClassifier` couvre POSIX + URLError, classifie `ECANCELED` comme récupérable uniquement dans `OutgoingTransferManager`.

### 4.4 Tests — bonne base
- 419 tests passants, 2 skipped documentés, 0 échec (446 s).
- Couverture forte sur : Security (90 tests), Transfer (120), Pairing (45), Protocol/Codec (55), Resume (35).
- Mocks appropriés (CryptoKit réel, NWConnection fakes, FileManager tmp).
- `setUp`/`tearDown` propres (UserDefaults cleared, dossiers tmp jetables).

### 4.5 Design system — propre
- `Design/` = 6 fichiers de tokens (couleurs, typo, espacement, radius, animations, kind).
- `minimumTapTarget = 44 pt` (HIG).
- `AirBridgeDesign.SystemColor` typé pour le respect d'`Increase Contrast`.
- Dynamic Type respecté via mapping `Font` SwiftUI.
- Light/Dark hérité des couleurs système.

### 4.6 UX déjà mature
- `RadarView` respecte Reduce Motion (sweep désactivé).
- `Transitions` (5 transitions nommées) sont propres et nommées (`cardAppear`, `rowAppear`, `alertAppear`, `tabSwitch`, `radarBubbleAppear`).
- `SpringAnimation` (standard/emphasized) et `AnimationCurve` (quick/standard/slow) bien définis.
- `TransferProgressView` : card riche (%, taille, speed, ETA, status badge, cancel/retry).
- `FileActionSheet` : AirDrop-like (Aperçu / Partager / Afficher / Supprimer de la liste / Supprimer du stockage / Supprimer les deux).
- `PendingApprovalCoordinator` : coalescence 400 ms → UX AirDrop "recevoir plusieurs fichiers d'un coup".
- Drag & drop global macOS sur fenêtre.
- Haptics sur transitions de statut (`fireHaptic(for:)`).
- `SoundService.play(.connected)` au handshake `.ready`.

---

## 5. Lacunes techniques

### 5.1 `AirBridgeCore.swift` = 3491 lignes (god class)

- Concentre 12+ collaborateurs directs, 25+ champs `@Observable`, 5 types internes liés au pipeline.
- `runChunkPipeline`, `PipelineWindow`, `OrderedAckPump`, `PipelineErrorSlot` sont des **types de Transfer** mais déclarés dans le Core.
- Méthode `configureBindings()` gigantesque qui chaîne des closures.
- Lit `connection.endpoint` à plusieurs endroits (fuite `NWConnection`).
- 3 sauts MainActor par message (`NWConnection` → `ConnectionManager` → `MessageRouter.onEvent` → `AirBridgeCore.onEvent`).

**Impact** : testabilité quasi-nulle, modifications risquées, compilation lente, hot reload cassé.

### 5.2 Code mort / stubs

- `Discovery/DiscoveryManager.swift` : 109 octets, 0 méthode (juste `import Foundation`).
- `ConnectionManager.waitForKeyExchangeAck(...)` : stub no-op.
- `TransferManager.sendChunk` (lignes 60-122) avec `maxPipelineDepth = 5` — mort, le pipeline actif est `AirBridgeCore.runChunkPipeline` avec `pipelineDepth = 4`.
- `OutgoingTransferManager.sendChunk` (compat) et `sendChunkAsync` (deprecated) coexistent.
- `LocalDeviceFactory.deviceIdentifier()` et `marketingModel()` déclarés mais non utilisés.
- `AirBridgeCore.encodeMessageWithBinaryPayload` est un placeholder.

### 5.3 Hétérogénéité des abstractions session

- `AirBridgeSession` (67 l., propre, jamais utilisé directement).
- `session: AirBridgeSession?` dans `ConnectionManager`.
- `activeSessionId: UUID?` dans `ConnectionManager`.
- `hasAdoptedSessionIdFromKeyExchange: Bool` dans `AirBridgeCore`.

### 5.4 Incohérence typographique

- `TransfertStorage.swift`, `TransfertTimeoutManager.swift` (accent "Transfert" vs "Transfer" partout ailleurs).

### 5.5 `decodedBinaryChunk` couplé à `ConnectionManager`

- `AirBridgeMessage` porte `decodedBinaryChunk` pour éviter un re-décodage binaire, mais reste lié au décodage v2 dans `ConnectionManager.receivePayload`.

### 5.6 Persistance éclatée

- `UserDefaults` : `airbridge.pairings.v1`, `airbridge.received-folder-bookmark`, `airbridge.localDeviceID`, `notificationsEnabled`.
- `Keychain` : `com.airbridge.identity`.
- Fichiers : `Documents/transfer_history.json`, `.partial` dans tmp.
- `TransferStore` en mémoire seulement.

### 5.7 `OutgoingSelectionPlanner.files(inFolderAt:)` ouvre un nouveau scope à chaque appel

- Si un `OutgoingSelectionPlan` est mis en file puis traité plus tard (FIFO), le scope est déjà rendu. Pas exploitable, mais design fragile.

### 5.8 Pas de couche « Use Case »

- Pas de découpage explicite entre orchestration et actions métier. `AirBridgeCore.importAndRequestItems(urls:)` fait : planning → file → FIFO → activation → handshake → push pipeline.

---

## 6. Lacunes UX/UI

### 6.1 Entrée tabée vs full-screen radar

- iOS utilise `TabView` (Appareils, Transferts, Réglages). AirDrop n'a pas de tab sur iPhone — le radar remplit l'écran.
- Le radar est dans un conteneur de 340 pt de haut, sur un VStack, suivi d'une liste horizontale de chips.
- **Notification de test** 2 s après lancement (`AirBridgeApp.swift:90-100`) — artefact dev en production.
- **Permission notifications** demandée au tout premier lancement (sans contexte).

### 6.2 `PairingConfirmationView` jamais présentée

- Vue existe, est implémentée et documentée (fingerprint, Trust/Block) mais **n'est jamais appelée** par `MainView`. L'utilisateur doit aller dans Réglages → Appareils appairés pour découvrir un pair en `pending`.
- `PairingDeviceCard` (plus belle que `PairedDeviceRow`) est définie mais non utilisée en `SettingsView`.
- Aucun code de vérification à 6 chiffres (à la AirDrop ancien / E2E messengers).
- Aucun contact photo (CNContact).
- Modèle « Everyone / Contacts Only » absent (juste `showAllRecipients` local dans `ShareViewModel`).

### 6.3 `ShareView` orphelin

- Vue entièrement implémentée (file picker, recipient selector, send button, previews, drop) et testée.
- **Aucun `NavigationLink` ni `.sheet` ne la présente depuis `MainView` ou `DiscoveryView`**.
- L'utilisateur réel passe par le bouton "Choisir un fichier" de `DiscoveryView` → file picker → les fichiers démarrent le transfert **sans écran de review**.
- Le recipient selector n'a aucun effet : `ShareViewModel.send(to:)` n'accepte que le pair connecté, peu importe le chip sélectionné.

### 6.4 `TransferRequestSheet` sans preview

- Affiche un `square.and.arrow.down` générique + liste monospaced de noms de fichiers.
- Pas de thumbnail par fichier (alors qu'`QLThumbnailGenerator` est disponible).
- Pas de `QuickLookPreview` sur iOS.
- Pas de `presentationDetents([.medium])` (cf. pairing sheet).

### 6.5 `TransferProgressView` partiellement accessible

- 18 occurrences de `.font(.system(size: x))` fixe — Dynamic Type non respecté sur icônes décoratives et boutons secondaires.
- `foregroundStyle(.green/.orange/.red/.gray)` contourne les tokens dans `SettingsView` (lignes 222-228) — `Increase Contrast` non respecté.
- Pas d'`accessibilityLabel`/`accessibilityHint` sur `MainView` (TabView) et `SettingsView`.

### 6.6 Pas de feedback cross-écrans

- Si l'utilisateur est sur un autre onglet qu'un transfert se termine : haptic OK mais feedback visuel invisible.
- Pas de `TransferCompletionBanner` overlay.
- Pas de Live Activity / Dynamic Island.

### 6.7 Pas de haptique de complétion distinctif

- `Haptics.success()` est une notification générique. AirDrop joue un pattern triple distinctif.

### 6.8 `SoundService` sous-employé

- Uniquement `play(.connected)` au handshake `.ready`.
- Pas de son pour : file added, send start, send complete, receive complete, pairing success, receive request.

### 6.9 `AirBridgeApp.swift` : 7 `print()` sans `#if DEBUG`

- Fuite l'identité locale (nom, modèle, ID UUID), l'état des permissions, et l'envoi d'une notification de test.

### 6.10 `SettingsView` encore dans `/UI/` (legacy)

- Migré partiellement : Discovery / Sharing / Transfer / Pairing sont dans `/Features/`, mais Settings et MainView sont restés dans `/UI/`.
- L'utilisateur navigue entre 2 styles.

### 6.11 Filtre trusted-only local, pas global

- `showAllRecipients` est dans `ShareViewModel` — local à la vue de partage.
- AirDrop a un paramètre système « Recevoir de : Contacts uniquement / Tout le monde / Personne ».

---

## 7. Différences avec l'expérience AirDrop

| AirDrop | AirBridge | Localisation dans AirBridge |
|---|---|---|
| Radar plein écran au lancement | Radar 340 pt dans tab "Appareils" | `MainView.swift:118-133`, `DiscoveryView.swift:67-77` |
| Aucun tab sur iOS | TabView (Appareils / Transferts / Réglages) | `MainView.swift:118-133` |
| Photo de contact + nom | Icône device + nom device | `DeviceAvatarView.swift` |
| Vérification 6 chiffres / contact photo | Empreinte hex 16 octets | `PairingConfirmationView.swift:99-117` |
| Auto-popup au pair inconnu | Aucune popup, faut aller dans Réglages | `PairingConfirmationView` non branché |
| Sparkle + pulse de proximité | Transition `radarBubbleAppear` (scale) | `Transitions.swift:radarBubbleAppear` |
| "Contacts Only" / "Everyone" / "Off" | Pas d'équivalent | absent |
| Notification permission au premier transfert | Au premier lancement | `AirBridgeApp.swift:80-88` |
| Pop-up de réception avec preview | Pop-up avec liste de noms, icône générique | `TransferRequestSheet.swift` |
| Accepter/Refuser la pop-up | Présent | `TransferRequestSheet.swift:165-188` |
| "Afficher dans Fichiers" iOS | QLPreviewController sur le dossier Documents | `TransferView.swift:226-254` |
| Drag-onto-Dock macOS | Drag dans la fenêtre uniquement | `MainView.swift:61-71` |
| "Envoyer via AirDrop" depuis n'importe quelle app | Pas de Share Extension | absent |
| Live Activity iOS 16+ | Absent | pas d'ActivityKit |
| Background transfer | Aucun (`URLSessionConfiguration.background` absent) | absent |
| Haptique de complétion distinctif | `Haptics.success()` générique | `Haptics.swift:86-91` |
| Drop multiple → 1 pop-up | Présent via `PendingApprovalCoordinator` 400 ms | OK ✅ |
| Reveal in Finder (macOS) | Présent via `NSWorkspace` | `TransferView.swift:658-668` |
| Historique persistant avec opérations | Présent | `TransferView.swift:362-389` |
| Quick Look sur fichier reçu | Présent (`HistoryPreviewView`) | OK ✅ |

---

## 8. Fonctionnalités manquantes (par priorité)

### 🔴 CRITIQUE — bloquant pour l'identité AirDrop

1. **Share Extension système** (`.appex`) — sans elle, AirBridge demande 4 étapes là où AirDrop en demande 1.
2. **Auto-presentation de `PairingConfirmationView`** — actuellement la vue existe mais n'est jamais appelée.
3. **Preview des fichiers dans `TransferRequestSheet`** (PDF, image, vidéo via `QLThumbnailGenerator`).
4. **Suppression de la notification de test au démarrage** (`AirBridgeApp.swift:90-100`).
5. **Déplacer la demande de permission notifications** du 1er lancement vers le 1er envoi / 1ère acceptation.
6. **Suppression du SHA-256 logué en clair** (`Core/AirBridgeCore.swift:1368, 2788-2789`).

### 🟠 IMPORTANT — produit perçu comme « application de partage » plutôt que « transfert magique »

7. **Mode de visibilité global** « Everyone / Contacts Only / Off » dans Réglages.
8. **Device name éditable** (actuellement `UIDevice.current.name` figé).
9. **Filtrage de la découverte par mode de visibilité** (le Bonjour doit cesser de broadcaster si « Off »).
10. **`ShareView` doit être présenté** depuis `DiscoveryView` (écran de review-and-send).
11. **Drag & drop sur l'icône Dock** (macOS) — `application(_:openFiles:)` ou `DockDropHandler`.
12. **Branding de l'app** : une couleur d'accent (AirDrop utilise le bleu Apple) — pour le moment AirBridge hérite du system accent sans identité propre.
13. **Live Activity iOS 16+** pour les transferts actifs.

### 🟡 NICE TO HAVE — polish

14. Sparkle effect à l'apparition d'un nouveau pair.
15. Pulse de proximité basé sur RSSI.
16. Thumbnail dans `FilePreviewGrid` (envoyé).
17. `Haptics.transferCompleted()` triple-tap.
18. `SoundService.play(.transferCompleted)`.
19. `TransferCompletionBanner` overlay cross-écran.
20. Multi-recipient (envoyer à 3 pairs en un seul geste).
21. `PairedDeviceRow` → `PairingDeviceCard` dans Settings.
22. Background transfer (quand app suspendue).
23. Continuous AirDrop-like animation entre source et destination.
24. Filtre par « type de fichier » dans le radar (envoyé / reçu / tous).
25. "Tap to send" sans écran de review (raccourci pour les power users).

### 🟢 FUTUR — vision long terme

26. **Contacts.framework** : photo + nom depuis le carnet d'adresses.
27. **Continuité cross-device** : hand-off entre deux appareils Apple d'un même utilisateur.
28. **visionOS Spatializer** : radar en volume 3D ?
29. **Compression à la volée** (zstd ou LZFSE) sur les types MIME adaptés.
30. **Chiffrement post-quantique** (ML-KEM hybride) — anticipation NIST FIPS 203/204.

---

## 9. Problèmes de fiabilité

### 9.1 Pipeline & reprise
- `ChunkSink` est un actor : la sérialisation protège des races. ✅
- `IncomingFileWriter` tronque les fichiers `.partial` trop longs : ✅
- `ResumePersistence` est un actor : ✅
- `OutOfOrderChunkBuffer` testé : ✅
- `scheduleAutomaticResumeOnReconnect` testé : ✅
- **Mais** : pas de test E2E avec 2 devices physiques. La checklist `CLAUDE.md` reste manuelle.

### 9.2 Lifecycle app
- **Aucun `BGTaskScheduler` ni `beginBackgroundTask` visible** dans la base.
- Si l'utilisateur passe en arrière-plan pendant un transfert de >1 Go, iOS peut suspendre l'app après ~30 s.
- **Aucun test** foreground/background/terminate.
- Pas de `BGAppRefreshTask` ni de `BGProcessingTask` déclarés dans `Info.plist` (à vérifier — pas trouvé dans l'audit).

### 9.3 Concurrence
- `@MainActor` correctement utilisé sur les `ViewModel` et la signalisation Core.
- `nonisolated`/`static nonisolated`/`actor` correctement utilisés sur le chemin chaud.
- 5 `Task { @MainActor in }` résiduels dans `AirBridgeCore` (P3) — à examiner un par un.
- `OSAllocatedUnfairLock` pour `pipelineLock` : ✅ moderne Swift 6.

### 9.4 Robustesse réseau
- `NetworkErrorClassifier` couvre POSIX + URLError. ✅
- Reconnexion sur `.ready` via Bonjour. ✅
- Reprise interrompue via `ResumePersistence`. ✅
- `ECANCELED` traité comme récupérable uniquement dans `OutgoingTransferManager` — cohérent.
- **Mais** : pas de test d'interruption au milieu d'un chunk (le `ChunkPipelineNoLoss` simule).

### 9.5 Robustesse UI
- `Sendable` conformance sur `TransferUIModel`, `TransferUIStatus`, `TransferUIDirection`. ✅
- Throttle 10 FPS via `UIThrottle<UInt64>`. ✅
- `TransferViewModel.applyRepublish` invalide toutes les observations à 10 Hz, y compris pour les entrées terminales (P1 — optimisation possible).
- `Sendable` est respecté sur les projections UI.

### 9.6 Dette `print()`

- **327 `print()`** (Core 150, ConnectionManager 49, ITM 25, BonjourService 22, NotificationManager 19, TransferManager 10, autres 52).
- Aucun `Logger` / `os_log` / `OSLog` dans le projet.
- Coût CPU en Release, absence de niveaux, non-redactable pour Apple Privacy.
- **Aucun `#if DEBUG` autour des 150 prints du Core** — chemins de fichiers et état interne fuitent en Release.

---

## 10. Problèmes de sécurité

### 10.1 Ce qui est sain (préservation stricte)

- P-256 long-terme en Keychain, non-synchronisable.
- ECDH éphémère par session, HKDF-SHA256.
- ChaCha20-Poly1305, AAD = `transferID ‖ chunkIndex ‖ sessionId`.
- Signatures ECDSA sur JSON canonicalisé.
- Anti-replay (actor, 4096, TTL 300 s).
- `verify → observe` dans `runSecureReceptionPipeline`.
- `keyChangedDowngraded` (`trusted` → `pending` sur changement de clé).
- `selfPairingPrevented` (clé locale ≠ clé payload).
- TOFU documenté, mitigé par fingerprint humain.
- Pas de log de clé privée, secret symétrique, nonce, token.

### 10.2 Ce qui doit être corrigé

| # | Problème | Sévérité | Effort |
|---|---|---|---|
| S-1 | SHA-256 source/reçu logué en clair (`Core/AirBridgeCore.swift:1368, 2788-2789`) — permet profilage du contenu | 🔴 P0 | 1 h |
| S-2 | 2 `print` "DEBUG:" sans `#if DEBUG` (`NotificationManager.swift:198, 245`) — autorisation + sender name fuient en Release | 🟠 P1 | 30 min |
| S-3 | 327 `print()` sans `Logger` / `os_log` — coût CPU + leak d'état en Release | 🟠 P1 | 2-3 j |
| S-4 | 2 `print` état de sécurité (`ConnectionManager.swift:326, 209`) — "Clé publique DIFFÉRENTE" / "Signature invalide" en console | 🟠 P1 | 15 min |
| S-5 | 7 `print()` dans `AirBridgeApp.swift` sans `#if DEBUG` (nom, modèle, ID UUID local) | 🟠 P1 | 30 min |
| S-6 | TOFU + pas de TLS transport — risque MITM à la 1ère connexion, mitigé par fingerprint humain | 🟠 P1 (documenté) | — |
| S-7 | `TransferHistoryStore.swift:16` utilise `.first!` (force unwrap) | 🟡 P2 | 15 min |
| S-8 | `TransfertStorage.swift:5` (et `TransfertTimeoutManager.swift:5`) prints I/O sans garde | 🟡 P2 | 15 min |

### 10.3 Ce qui n'est pas un problème

- Le chiffrement est **intact** depuis la dernière release candidate.
- Le bug "Clé publique annoncée DIFFÉRENTE" est résolu (`extractAdvertisedPublicKey` lignes 246-280).
- Le bug "Signature invalide pour transferAccepted" est résolu (`SecureIdentityStore.sign()` charge la clé long-terme Keychain, `send()` signe automatiquement).

---

## 11. Gestion des fichiers

### 11.1 Émission
- `OutgoingSelectionPlanner` (311 l.) : expansion de dossiers, déduplication, calcul de taille.
- `OutgoingTransferQueue` : FIFO `@MainActor @Observable`, `enqueue`, `activate`, `finish`, `cancel`, `cancelAll`.
- `OutgoingTransferManager` (493 l.) : `sendChunkOverConnectionStatic` est `static nonisolated`.
- `OutgoingFileSource` : 13 l. POD.

### 11.2 Réception
- `IncomingFileWriter` (197 l.) : `FileHandle` + `.partial` dans tmp + `close()` → `synchronize()` + `close()`.
- `IncomingTransferManager` (673 l.) : `ChunkSink` actor, batch tally (`fileCount`, `totalBytes`), `ReceivedBatchLimits` validation, `ReceivedBatchLayout` disposition.
- `ChunkStreamCipher` : `nonisolated struct` à `let key` immuable.

### 11.3 Persistance
- `TransferStore` (223 l.) : en mémoire seulement — **redémarrage = perte si pas `.interrupted`**.
- `TransferHistoryStore` (79 l.) : JSON dans `Documents/transfer_history.json`.
- `ResumePersistence` (71 l.) : actor, JSON dans `Application Support/AirBridge/ResumableTransfers/`.

### 11.4 Folder de réception
- `ReceivedFolderStore` : security-scoped bookmark (correct pour macOS sandbox).
- `#if os(macOS)` pour la sélection.
- Sur iOS : `URL.documentsDirectory` (codé en dur dans `TransferViewModel.swift:489-495`).
- Pas de sélection de dossier personnalisé sur iOS.

### 11.5 Intégrité
- `FileHasher` (69 l.) : SHA-256 streaming.
- Vérification à `transferCompleted` (signé).
- **Mais** : pas de test E2E round-trip SHA-256 (la checklist `CLAUDE.md` reste manuelle).

### 11.6 Atomicité
- `.partial` → fichier final uniquement à la fin du transfert (✅).
- `IncomingFileWriter.close()` fait `synchronize()` + `close()` (✅).

---

## 12. iOS — analyse spécifique

### 12.1 Compilation
- iOS 17+ (cible). `ContentUnavailableView` est disponible.
- SDK macOS 26.5 (Xcode 26).
- `project.pbxproj` : cible iPhone + iPad.

### 12.2 UX iOS
- `TabView` 3 sections (vs AirDrop : aucun).
- Pas de swipe-back-to-radar après l'envoi.
- `TransferView` accessible via l'onglet Transferts.
- `SettingsView` accessible via l'onglet Réglages.
- `TransferRequestSheet` : modal plein écran (pas de `presentationDetents`).
- `PairingConfirmationView` : jamais présentée (n'existe qu'en code mort).

### 12.3 Drag & drop iOS
- iPad : drop sur `ShareView` (`ShareView.swift:99-112`).
- iPhone : pas de drop (limitation attendue).
- iOS-iPad : pas de drop sur `DiscoveryView` (pourquoi pas ?).

### 12.4 Permissions iOS
- `NSLocalNetworkUsageDescription` : présent dans `Info.plist` ? (à vérifier — pas trouvé dans le fichier lu).
- `NSBonjourServices` : présent (`_airbridge._tcp`).
- `UIFileSharingEnabled` : présent.
- `LSSupportsOpeningDocumentsInPlace` : présent.
- Demande au premier appel Bonjour, pas au premier lancement.

### 12.5 Notifications iOS
- `interruptionLevel = .timeSensitive` ✅
- Catégorisation par `direction` et `deviceName` (publics) ✅
- Actions Accept/Reject câblées ✅
- Pas d'attachement (`UNNotificationAttachment`) pour preview.

### 12.6 Haptics iOS
- `UIFeedbackGenerator` réels : ✅
- 21 appels répartis.
- Manque : `Haptics.transferCompleted()` triple-tap.

### 12.7 Problèmes iOS
- 18 `.font(.system(size: x))` fixe (`TransferProgressView`) — Dynamic Type non respecté.
- `foregroundStyle(.green/.orange/.red/.gray)` dans `SettingsView` (lignes 222-228) — `Increase Contrast` non respecté.
- Pas de preview dans `TransferRequestSheet`.
- Pas de background transfer (`URLSessionConfiguration.background`).

---

## 13. macOS — analyse spécifique

### 13.1 Compilation
- macOS 14+ (cible).
- Universal app (même scheme).
- Drag & drop global sur fenêtre (`MainView.swift:61-71`).

### 13.2 UX macOS
- `NavigationSplitView` 3 sections (mêmes que iOS).
- Drop global : overlay "Dépose pour envoyer" (✅).
- "Afficher dans le Finder" via `NSWorkspace.activateFileViewerSelecting` (✅).
- "Ouvrir avec" via `NSWorkspace.shared.open(url)` (✅).

### 13.3 macOS-only
- `FloatingActionBar` (legacy /UI/).
- `ActionLabel` (legacy /UI/).
- `handleGlobalDrop` macOS-only.

### 13.4 Drag & drop macOS
- Sur fenêtre : ✅
- Sur icône Dock : ❌ (pas de `application(_:openFiles:)`).
- Drop sur `ShareView` : global fenêtre suffit.

### 13.5 Sandbox macOS
- `ReceivedFolderStore` security-scoped bookmark : ✅
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` : ✅ (Keychain)

### 13.6 Problèmes macOS
- Pas de `DockDropHandler` pour drag depuis Finder sur l'icône.
- Pas de menu contextuel sur fichier dans Finder ("Envoyer via AirBridge").
- Pas de barre de progression dans la Touch Bar (deprecated, mais utile pour vérifier l'app).

---

## 14. visionOS — analyse spécifique

### 14.1 Compilation
- `xros` et `xrsimulator` dans `SUPPORTED_PLATFORMS` (`project.pbxproj`).
- Le code utilise SwiftUI standard : devrait compiler.

### 14.2 UX visionOS (hypothèses, **non testé**)
- Le `RadarView` (concentric rings + sweep) devrait s'afficher correctement dans une `WindowGroup`.
- `PairingConfirmationView` non présentée = UX cassée sur visionOS aussi.
- Pas de `RealityView` ni d'orchestration spatiale.
- Pas de validation de confort (taille de police, distance).

### 14.3 Recommandations
- **Tester** sur `xrsimulator` avec une build dédiée.
- **Adapter** le radar pour un affichage en volume (sphère de pairs) ?
- **Respecter** les patterns visionOS : `ornament` pour la barre d'onglets, focus management pour le radar.
- **Vérifier** la compatibilité `TransferRequestSheet` (modal volumétrique sur visionOS ?).

### 14.4 Risques visionOS
- Si une vue est trop dense, l'app pourrait être rejetée par l'App Review.
- `import Network` est conservé sur visionOS — aucune restriction connue.

---

## 15. Tests manquants

### 15.1 Manques critiques
- **Aucun test E2E 2-simulateurs** (transfert Mac → iPhone simulé).
- **Aucun test BonjourService réel** (faux NWBrowser).
- **Aucun test ConnectionManager lifecycle** (`NWConnection.start` → `.ready` → `.failed`).
- **Aucun test AirBridgeApp lifecycle** (foreground/background/terminate).
- **Aucun test de background transfer**.
- **Aucun test de notification** (Accept/Reject depuis notif système).
- **Aucun test de Drag & Drop Dock icon**.
- **Aucun test Share Extension** (pas d'extension, pas de cible de test).
- **Aucun test de permission denied** (notifications, local network).
- **Aucun test de fingerprint mismatch**.
- **Aucun test de self-pairing prevention** au niveau de la vue (uniquement au niveau Core).
- **Aucun test `FileHasher` round-trip** (SHA-256 source == SHA-256 reçu).
- **Aucun test de découverte sans pair** (`DiscoveryView` avec 0 devices).
- **Aucun test `SettingsView` migration** vers `/Features/Settings/`.

### 15.2 Manques de robustesse
- **Aucun test multi-device simultané** (le FIFO est single-peer).
- **Aucun test de race condition** sur `OutgoingTransferQueue` (2 threads en concurrence).
- **Aucun test de fuite mémoire** (`weak` capture sur les callbacks Core).
- **Aucun test de crash recovery** (kill -9 en milieu de transfert).
- **Aucun test de `TransferStore` persistence** (redémarrage en cours de transfert).
- **Aucun test de `TransferHistoryStore` corruption recovery**.

### 15.3 Manques d'accessibilité
- **Aucun test VoiceOver** (labels, hints, traits).
- **Aucun test Dynamic Type** (xxLarge).
- **Aucun test Reduce Motion** (sweep désactivé sur le radar — testé manuellement).
- **Aucun test Increase Contrast**.

### 15.4 Manques UI/SwiftUI
- **Aucun snapshot test** (`swift-snapshot-testing` n'est pas dans le projet).
- **Aucun test de rendering** de `RadarView`, `TransferProgressView`, `FileActionSheet`.
- **Aucun test de haptic** (sandbox iOS simulé).
- **Aucun test de `UIThrottle` en concurrence**.

### 15.5 Manques de benchmark
- **Aucun benchmark comparatif** avant/après refactor MainActor-out.
- **`TransferPerformanceBenchmarks` existe** mais `XCTMeasure` n'est pas gate par CI.

### 15.6 Recommandations d'outillage
- Ajouter `swift-snapshot-testing` pour les vues SwiftUI.
- Migrer vers Swift Testing (`@Test`, `#expect`) pour les nouveaux tests (paramétrage plus simple).
- Ajouter une CI GitHub Actions : `xcodebuild test -destination "platform=iOS Simulator,name=iPhone 15"` + macOS.
- Ajouter des tests E2E 2-simulateurs (`xcodebuild test -destination "platform=iOS Simulator,name=..."` × 2).

---

## 16. Dette technique (classification)

### 16.1 Architecture
- 🔴 `AirBridgeCore.swift` = 3491 l. (god class).
- 🔴 `ConnectionManager.swift` = 1531 l. (à découper en 4 fichiers).
- 🟠 `TransferManager.swift` = 884 l. (contient du code mort).
- 🟠 5 `Task { @MainActor in }` résiduels dans `AirBridgeCore`.
- 🟠 3 abstractions pour « session » (unifier).
- 🟡 `decodedBinaryChunk` couplé à `ConnectionManager` (hack de perf).
- 🟡 Pas de couche Use Case.

### 16.2 Code mort
- 🔴 `Discovery/DiscoveryManager.swift` (109 octets, 0 méthode).
- 🔴 `ConnectionManager.waitForKeyExchangeAck(...)` (stub no-op).
- 🟠 `TransferManager.sendChunk` (lignes 60-122, `maxPipelineDepth=5`).
- 🟠 `OutgoingTransferManager.sendChunk` (compat) + `sendChunkAsync` (deprecated).
- 🟡 `LocalDeviceFactory.deviceIdentifier()` / `marketingModel()`.
- 🟡 `AirBridgeCore.encodeMessageWithBinaryPayload` (placeholder).
- 🟡 `TransferManager.pendingChunks` (marqué non utilisé).

### 16.3 Couplage UI/Core
- 🟠 `SettingsView` lit `PairingStore` directement (fuite).
- 🟠 `DiscoveryView` lit `core.pairingStore.loadAll()` directement.
- 🟠 `MainView` consomme 3 services Core directement.
- 🟡 `ShareView` importe `Network` (fuite).

### 16.4 Incohérences
- 🟡 `TransfertStorage.swift` / `TransfertTimeoutManager.swift` (accent incohérent).
- 🟡 `SettingsView` reste dans `/UI/` (legacy) pendant que tout le reste migre vers `/Features/`.
- 🟡 `ContentUnavailableView` utilisé 2 fois, le reste de l'app utilise des `VStack` custom.

### 16.5 Logs
- 🔴 327 `print()` (Core 150, CM 49, ITM 25, etc.).
- 🔴 1 leak SHA-256 (P0).
- 🟠 0 `Logger` / `os_log` / `OSLog`.
- 🟠 0 `#if DEBUG` autour des prints.

### 16.6 Persistance
- 🟠 Éclatement entre UserDefaults / Keychain / JSON / tmp.
- 🟡 `TransferStore` en mémoire seulement.
- 🟡 `TransfertStorage.swift:16` force unwrap (`.first!`).

### 16.7 Tests
- 🟠 Pas de 2-simulator E2E.
- 🟠 Pas de snapshot tests.
- 🟠 Pas de tests UI/accessibility.
- 🟡 Pas de CI.
- 🟡 Pas de benchmark CI.

---

## 17. Fonctionnalités prioritaires (par ROI)

| # | Fonctionnalité | Impact UX | Difficulté | Risque | ROI |
|---|---|---|---|---|---|
| 1 | **Brancher `PairingConfirmationView` en auto-popup** | 🔴 Élevé | S | Faible | ⭐⭐⭐⭐⭐ |
| 2 | **Supprimer la notification de test au démarrage** | 🔴 Élevé | XS | Très faible | ⭐⭐⭐⭐⭐ |
| 3 | **Déplacer la permission notifications au 1er envoi/accept** | 🔴 Élevé | S | Faible | ⭐⭐⭐⭐⭐ |
| 4 | **Brancher `ShareView` dans la navigation** (review-and-send) | 🔴 Élevé | M | Faible | ⭐⭐⭐⭐⭐ |
| 5 | **Preview fichiers dans `TransferRequestSheet`** (QLThumbnailGenerator) | 🟠 Élevé | M | Faible | ⭐⭐⭐⭐ |
| 6 | **Mode de visibilité "Contacts Only / Everyone / Off"** | 🟠 Élevé | M | Faible | ⭐⭐⭐⭐ |
| 7 | **Device name éditable dans Réglages** | 🟡 Moyen | S | Faible | ⭐⭐⭐⭐ |
| 8 | **Share Extension système (`.appex`)** | 🔴 Élevé | L | Moyen | ⭐⭐⭐⭐ |
| 9 | **Drag & Drop sur icône Dock (macOS)** | 🟡 Moyen | M | Faible | ⭐⭐⭐ |
| 10 | **Live Activity iOS 16+** | 🟡 Moyen | L | Faible | ⭐⭐⭐ |
| 11 | **`PairedDeviceRow` → `PairingDeviceCard`** | 🟡 Moyen | XS | Très faible | ⭐⭐⭐ |
| 12 | **Suppression du SHA-256 logué** | 🔴 Sécurité | XS | Très faible | ⭐⭐⭐⭐⭐ |
| 13 | **Remplacer `print()` par `os_log`/`Logger`** | 🟠 Sécurité/hygiene | M | Faible | ⭐⭐⭐ |
| 14 | **Découper `AirBridgeCore` (god class)** | 🟡 Architecture | XL | Élevé | ⭐⭐⭐ |
| 15 | **Découper `ConnectionManager` (1531 l.)** | 🟡 Architecture | M | Moyen | ⭐⭐ |
| 16 | **Supprimer code mort (DiscoveryManager, sendChunk, etc.)** | 🟡 Clarté | S | Très faible | ⭐⭐⭐ |
| 17 | **CI GitHub Actions + 2-simulator E2E** | 🟡 Qualité | M | Faible | ⭐⭐⭐⭐ |
| 18 | **Migrer Settings vers `/Features/Settings/`** | 🟡 Cohérence UI | M | Faible | ⭐⭐⭐ |
| 19 | **Sparkle + pulse de proximité sur nouveau pair** | 🟡 Polish | M | Faible | ⭐⭐ |
| 20 | **Background transfer (BGTaskScheduler / beginBackgroundTask)** | 🟠 Élevé | M | Moyen | ⭐⭐⭐ |

**XS** < 1 h · **S** < 1 j · **M** 1-3 j · **L** 4-7 j · **XL** > 1 sem.

---

## 18. Roadmap complète

> Les phases sont ordonnées pour **maximiser la valeur utilisateur rapidement** tout en **préservant l'architecture existante** (sécurité intacte, pas de migration risquée).

### Phase 0 — Quick wins sécurité & UX (1-2 jours)

**Objectif** : retirer ce qui fait tache sans rien casser.

**Features** :
- Retirer la notification de test au démarrage (`AirBridgeApp.swift:90-100`).
- Déplacer la permission notifications au 1er envoi / 1ère acceptation.
- Supprimer le SHA-256 logué en clair (P0-1).
- Garder `#if DEBUG` autour des prints qui exposent l'identité locale.
- Remplacer `print` "DEBUG:" par `os_log` (P1-1).
- Garder `foregroundStyle` aligné sur les tokens dans `SettingsView` (P2-4).

**Fichiers** :
- `AirBridge/AirBridgeApp.swift`
- `Core/AirBridgeCore.swift` (lignes 1368, 2788-2789)
- `Notifications/NotificationManager.swift:198, 245`
- `UI/Settings/SettingsView.swift:222-228`

**Architecture** : aucune modification.

**Dépendances** : aucune.

**Risques** : aucun (toutes les modifications sont localisées, isolables, réversibles).

**Tests** : exécution de la suite 419 tests existants — pas de régression attendue.

**Critères d'acceptation** :
- ✅ Plus de notification "1 fichier reçu depuis Test Appareil" au lancement.
- ✅ Plus de demande de permission au 1er lancement.
- ✅ Aucun SHA-256 en clair dans les logs de Release.
- ✅ Aucun "DEBUG:" en Release.
- ✅ Tests passent.

### Phase 1 — Brancher les vues orphelines (3-5 jours)

**Objectif** : faire vivre ce qui existe déjà.

**Features** :
- **Brancher `PairingConfirmationView`** : `MainView` présente la sheet dès que `core.pairingStore.currentPeerNeedsPairing` devient `true`.
- **Brancher `ShareView`** dans la navigation depuis `DiscoveryView` : un sheet apparaît après le file picker pour le review-and-send.
- **Remplacer `PairedDeviceRow`** par `PairingDeviceCard` dans `SettingsView`.

**Fichiers** :
- `UI/MainView.swift` (nouveau `@State var presentedPairing` + `.sheet`)
- `Features/Discovery/DiscoveryView.swift` (nouveau `.sheet` pour `ShareView`)
- `UI/Settings/SettingsView.swift` (substitution)

**Architecture** : aucune modification de Core. Juste wiring UI.

**Dépendances** : aucune (les vues existent).

**Risques** : aucun (les vues ont déjà leurs tests `PairingViewModelTests`, `ShareViewModelTests`).

**Tests** :
- `PairingViewModelTests` : ajouter `testCurrentPeerNeedsPairingTurnsTrueOnConnection` (utilise un faux `ConnectionManager`).
- `ShareViewModelTests` : couvrir le flow "files selected → recipient selected → send" (au moins partiellement).
- `SettingsViewSnapshotTests` : nouveau fichier (à créer).

**Critères d'acceptation** :
- ✅ Un nouveau pair non-appairé déclenche la sheet `PairingConfirmationView` dans la seconde qui suit.
- ✅ Après "Choisir un fichier", un sheet `ShareView` apparaît pour review.
- ✅ La section Appareils appairés affiche `PairingDeviceCard`.
- ✅ Tests passent.

### Phase 2 — Preview des fichiers (3-5 jours)

**Objectif** : "voir ce qu'on envoie" avant que ça parte.

**Features** :
- **`TransferRequestSheet` avec thumbnails** : `QLThumbnailGenerator` (iOS) / `QuickLookThumbnailing` (macOS) pour image / vidéo / PDF.
- **`FilePreviewGrid` avec thumbnails** : même technique, côté envoi.
- **`HistoryPreviewView`** : déjà fait, à conserver.
- **QuickLook preview** : tap sur un fichier dans `TransferRequestSheet` ouvre un QuickLook modal.

**Fichiers** :
- `Features/Transfer/TransferRequestSheet.swift`
- `Features/Sharing/FilePreviewGrid.swift`
- `Features/Sharing/FilePreviewItem.swift`
- Nouveau : `Features/Common/ThumbnailLoader.swift` (actor pour les générations concurrentes).

**Architecture** : aucun changement de Core.

**Dépendances** : `QuickLookThumbnailing` (déjà disponible iOS 14+ / macOS 10.15+).

**Risques** : faible. La génération de thumbnail peut être lente sur des fichiers lourds → utiliser un actor + cache.

**Tests** :
- `ThumbnailLoaderTests` : test de l'actor avec un faux `QLThumbnailGenerator` (DI).
- `FilePreviewGridSnapshotTests` : nouveaux tests.

**Critères d'acceptation** :
- ✅ Un JPEG / PNG / HEIC montre un thumbnail 100×100 dans `TransferRequestSheet`.
- ✅ Une vidéo montre la première frame.
- ✅ Un PDF montre la première page.
- ✅ Un ZIP / binaire montre une icône de fallback.
- ✅ Tests passent.

### Phase 3 — Visibilité & device name (3-5 jours)

**Objectif** : rendre AirBridge configurable au niveau utilisateur.

**Features** :
- **Mode de visibilité** : `Everyone / Contacts Only / Off` (segmented control dans `SettingsView`).
- **Implémenter "Contacts Only"** : filtre des `DiscoveredDevice` selon une whitelist de `publicKeyData` autorisée (à enrichir par tap "Ajouter contact").
- **Implémenter "Off"** : le `BonjourService` cesse de broadcaster (et le `NWBrowser` ignore les pairs).
- **Device name éditable** : champ texte dans Réglages → `LocalDeviceFactory` consomme un `UserDefaults` (clé `airbridge.device-name`).
- **Privacy Manifest** : déclarer les API "Required Reason" (UserDefaults, Bonjour, Keychain).

**Fichiers** :
- `UI/Settings/SettingsView.swift`
- `Discovery/BonjourService.swift` (ajout du mode de visibilité)
- `Discovery/LocalDeviceFactory.swift`
- `UI/MainView.swift` (consommer le nouveau device name)
- Nouveau : `AirBridge/PrivacyInfo.xcprivacy`

**Architecture** : nouvelle option `@AppStorage("airbridge.visibility")` consommée par `BonjourService`.

**Dépendances** : aucune.

**Risques** : faible. "Off" doit cesser de broadcaster sans casser la découverte locale (test de régression nécessaire).

**Tests** :
- `BonjourServiceTests` : nouveau test "Off → NWListener.stop()".
- `LocalDeviceFactoryTests` : nouveau test "device name from UserDefaults".

**Critères d'acceptation** :
- ✅ L'utilisateur peut choisir entre 3 modes dans Réglages.
- ✅ Le mode "Off" coupe la découverte.
- ✅ Le device name est éditable et persiste.
- ✅ Le Privacy Manifest est validé par `xcrun xcprivacy`.

### Phase 4 — Share Extension (1-2 semaines)

**Objectif** : invoquer AirBridge depuis n'importe quelle app.

**Features** :
- **Nouvelle cible `.appex`** (Share Extension) dans le projet Xcode.
- **`ShareViewController`** : `SLComposeServiceViewController` ou extension custom SwiftUI.
- **Communication** : App Groups (`group.com.airbridge.shared`) + UserDefaults partagé + file d'attente.
- **L'app hôte** lit la file au prochain lancement.

**Fichiers** :
- Nouveau target : `AirBridgeShareExtension/`
  - `ShareViewController.swift`
  - `Info.plist` (extension point)
  - `MainInterface.storyboard` ou SwiftUI
- Nouveau : `AirBridge/Shared/SharedTransferQueue.swift` (actor partagé).
- `project.pbxproj` : nouvelle cible.

**Architecture** : App Group = sandbox partagé pour `SharedTransferQueue`.

**Dépendances** : aucune (Foundation + Network).

**Risques** : moyen. Le sandbox de l'extension est limité, et la communication avec l'app hôte est asynchrone. Tests E2E requis.

**Tests** :
- `ShareExtensionTests` : nouvelle cible de test, simule l'invocation depuis Safari / Photos.
- `SharedTransferQueueTests` : test de l'actor avec file partagée.

**Critères d'acceptation** :
- ✅ "AirBridge" apparaît dans la feuille de partage système.
- ✅ Sélectionner un fichier dans Photos / Safari et choisir AirBridge → fichier mis en file.
- ✅ L'app hôte traite la file au prochain lancement (ou via background fetch).
- ✅ Tests passent.

### Phase 5 — Drag & drop Dock + Feedback cross-écrans (3-5 jours)

**Objectif** : ouvrir AirBridge sans cliquer son icône, et informer l'utilisateur même quand il n'est pas sur l'onglet Transferts.

**Features** :
- **Drag & drop Dock icon (macOS)** : `NSApplicationDelegate.application(_:openFiles:)` → appelle `core.importAndRequestItems(urls:)`.
- **`TransferCompletionBanner` overlay** : quand un transfert se termine hors de l'onglet Transferts, un toast apparaît 4 s en haut de l'écran.
- **Haptique de complétion distinctif** : `Haptics.transferCompleted()` triple-tap (3x `notificationOccurred(.success)` à 80 ms d'intervalle).
- **Son de complétion** : `SoundService.play(.transferCompleted)` avec un SystemSound distinctif (ex: 1057 → 1003 "Tink" → 1004 "Tock" ou un pattern à 2 sons).

**Fichiers** :
- `App/AirBridgeApp.swift` : ajout `application(_:openFiles:)`.
- Nouveau : `Features/Transfer/TransferCompletionBanner.swift`.
- `Features/Common/Haptics.swift` : ajout `transferCompleted()`.
- `Features/Common/SoundService.swift` : ajout `play(.transferCompleted)`.

**Architecture** : nouveau service de notifications in-app, consommé par `MainView`.

**Dépendances** : aucune.

**Risques** : faible.

**Tests** :
- `HapticsTests` : nouveau test mock pour le triple-tap.
- `SoundServiceTests` : nouveau test mock.
- `TransferCompletionBannerSnapshotTests` : nouveaux tests.

**Critères d'acceptation** :
- ✅ Glisser un fichier sur l'icône Dock démarre un transfert (si pair connecté).
- ✅ Un transfert terminé affiche un toast 4 s (même hors onglet Transferts).
- ✅ Le triple-tap haptique est distinctement ressenti.
- ✅ Le son de complétion est distinctif.
- ✅ Tests passent.

### Phase 6 — Live Activity & Background transfer (1-2 semaines)

**Objectif** : informer l'utilisateur même app fermée, et terminer les transferts en arrière-plan.

**Features** :
- **Widget Extension (`.widgetkit`)** pour Live Activity.
- **`TransferLiveActivity` widget** : affiche %, taille, ETA, peer.
- **Background transfer** : `URLSessionConfiguration.background` équivalent — probablement en réécrivant la couche réseau pour utiliser `URLSession` au lieu de `NWConnection` (attention, gros changement). Alternative : `beginBackgroundTask` + `BGTaskScheduler`.
- **`BGAppRefreshTask`** enregistré dans `Info.plist` pour le wake périodique.

**Fichiers** :
- Nouveau target : `AirBridgeWidget/`
  - `TransferLiveActivity.swift`
  - `TransferActivityAttributes.swift`
- `Notifications/NotificationManager.swift` : ajout `startLiveActivity` / `updateLiveActivity`.
- `Network/ConnectionManager.swift` : ajout `beginBackgroundTask` / `endBackgroundTask`.
- `AirBridge/Info.plist` : ajout `BGTaskSchedulerPermittedIdentifiers`.

**Architecture** : Live Activity = extension cible séparée. Background = `beginBackgroundTask` autour de `runChunkPipeline`.

**Dépendances** : `ActivityKit` (iOS 16.1+).

**Risques** : élevé. La réécriture de la couche réseau est un pari. **Recommandation** : faire Live Activity en premier, background en second, en gardant la possibilité de rollback.

**Tests** :
- `TransferActivityAttributesTests` : nouveau test.
- `LiveActivitySimulationTests` : nouveau test avec un mock `ActivityKit`.

**Critères d'acceptation** :
- ✅ Un transfert actif apparaît dans la Dynamic Island et l'écran verrouillé.
- ✅ Le tap sur la Live Activity ouvre l'app sur l'onglet Transferts.
- ✅ Un transfert >500 Mo survit à un background de 30 s.
- ✅ Tests passent.

### Phase 7 — God class refactor (2-3 semaines, optionnel mais recommandé)

**Objectif** : ramener `AirBridgeCore` à < 800 lignes en extrayant 5-6 orchestrateurs.

**Features** :
- `SessionOrchestrator` (~500 l.) : session, isConnected, coordination `ConnectionManager` ↔ reste.
- `OutgoingFlow` (~700 l.) : `OutgoingTransferQueue`, `importAndRequestItems`, FIFO, security-scoped, SHA-256, originaux.
- `IncomingFlow` (~600 l.) : `PendingApprovalCoordinator`, `TransferRequestSheet` binding, accept/reject, `BatchContext`, `ReceivedBatchLayout`.
- `Transfer/Pipeline/PipelineWindow.swift` + `OrderedAckPump.swift` + `PipelineErrorSlot.swift` (déplacés hors du Core).
- `ResumeOrchestrator` (~300 l.) : `resumeTasks`, `isResumeCampaignActive`, backoff.
- `PairingOrchestrator` (~400 l.) : `pendingPairingChallenges`, `pendingECDHHandshake`, flux `keyExchange/keyExchangeAck/pairingRequest/pairingResponse`.
- `AirBridgeCore` réduit à un façade (500-800 l.) qui possède les 6 orchestrateurs + `ConnectionManager`.

**Fichiers** : nombreux (refactor).

**Architecture** : introduit une couche « Orchestrator » entre Core et managers.

**Dépendances** : aucune (refactor pur).

**Risques** : élevé. Chemin critique. Refactor doit être fait **par phases** avec tests de caractérisation.

**Tests** : tous les 419 tests doivent continuer à passer après chaque étape.

**Critères d'acceptation** :
- ✅ `AirBridgeCore.swift` < 800 l.
- ✅ Aucun orchestrateur > 800 l.
- ✅ Les tests passent.
- ✅ Aucune régression de performance.

### Phase 8 — Polish (1 semaine)

**Objectif** : tous les nice-to-have qui rendent l'app mémorable.

**Features** :
- Sparkle + pulse de proximité (DeviceRadarItem).
- `foregroundStyle` aligné sur tokens (Settings).
- Dynamic Type complet (TransferProgressView).
- `Haptics.selection()` sur tous les taps de chip.
- Continuous AirDrop-like animation entre source/destination.
- Mode "Tap to send" (sans review) derrière un toggle.
- Privacy Manifest validé.

**Fichiers** : dispersés (polish).

**Critères d'acceptation** :
- ✅ L'app se sent « soignée » sur tous les appareils.

### Phase 9 — Long terme (4-12 mois)

- Contacts.framework (photo + nom).
- Continuité cross-device.
- visionOS spatialization.
- Compression à la volée.
- Chiffrement post-quantique.

---

## 19. Détail de chaque phase (template par phase)

Pour chaque phase ci-dessus, voici le détail standard :

### Phase X — [Nom]

**Objectif** : [1 phrase]

**Features** :
- [Feature 1]
- [Feature 2]
- [Feature 3]

**Fichiers** :
- [Chemin 1]
- [Chemin 2]

**Architecture** :
- [Changement architectural, ou "aucun"]

**Dépendances** :
- [Nouvelle dépendance, ou "aucune"]

**Risques** :
- [Risque 1 + mitigation]
- [Risque 2 + mitigation]

**Tests** :
- [Test nouveau 1]
- [Test nouveau 2]
- [Suite 419 existante : doit passer]

**Critères d'acceptation** :
- ✅ [Critère 1]
- ✅ [Critère 2]
- ✅ [Critère 3]

(voir section 18 pour le détail par phase)

---

## 20. Ordre exact d'implémentation

### Sprint 0 (1-2 jours) — Quick wins sécurité & UX
1. Retirer la notification de test au démarrage.
2. Déplacer la permission notifications au 1er envoi/accept.
3. Supprimer le SHA-256 logué en clair.
4. Garder `#if DEBUG` autour des prints qui exposent l'identité locale.
5. Remplacer `print` "DEBUG:" par `os_log`.
6. Garder `foregroundStyle` aligné sur tokens dans `SettingsView`.

### Sprint 1 (3-5 jours) — Brancher les vues orphelines
7. Brancher `PairingConfirmationView` en auto-popup.
8. Brancher `ShareView` dans la navigation (review-and-send).
9. Remplacer `PairedDeviceRow` par `PairingDeviceCard` dans `SettingsView`.

### Sprint 2 (3-5 jours) — Preview des fichiers
10. Créer `ThumbnailLoader` actor.
11. Ajouter thumbnails dans `TransferRequestSheet`.
12. Ajouter thumbnails dans `FilePreviewGrid`.
13. QuickLook preview sur tap dans `TransferRequestSheet`.

### Sprint 3 (3-5 jours) — Visibilité & device name
14. Ajouter Privacy Manifest.
15. Ajouter mode de visibilité (Everyone / Contacts Only / Off).
16. Implémenter "Contacts Only" avec whitelist.
17. Implémenter "Off" (coupe la découverte).
18. Device name éditable.

### Sprint 4 (1-2 semaines) — Share Extension
19. Créer nouvelle cible `.appex`.
20. Implémenter `ShareViewController` SwiftUI.
21. Créer `SharedTransferQueue` actor (App Group).
22. Câbler l'app hôte.

### Sprint 5 (3-5 jours) — Drag & drop Dock + Feedback cross-écrans
23. Drag & drop Dock icon macOS.
24. `TransferCompletionBanner` overlay.
25. `Haptics.transferCompleted()` triple-tap.
26. `SoundService.play(.transferCompleted)`.

### Sprint 6 (1-2 semaines) — Live Activity & Background transfer
27. Widget Extension cible.
28. `TransferLiveActivity`.
29. `beginBackgroundTask` pour les transferts >500 Mo.
30. `BGAppRefreshTask` registered.

### Sprint 7 (2-3 semaines) — God class refactor (optionnel mais recommandé)
31. Extraire `SessionOrchestrator`.
32. Extraire `OutgoingFlow`.
33. Extraire `IncomingFlow`.
34. Déplacer `PipelineWindow` / `OrderedAckPump` / `PipelineErrorSlot` vers `Transfer/Pipeline/`.
35. Extraire `ResumeOrchestrator`.
36. Extraire `PairingOrchestrator`.
37. Réduire `AirBridgeCore` à un façade < 800 l.

### Sprint 8 (1 semaine) — Polish
38. Sparkle + pulse de proximité.
39. Dynamic Type complet.
40. `Haptics.selection()` sur tous les taps.
41. Privacy Manifest validé.

### Sprint 9 (1-2 semaines) — Tests & CI
42. Snapshot tests pour les vues SwiftUI.
43. Tests E2E 2-simulateurs.
44. CI GitHub Actions.
45. Migrer vers Swift Testing (au moins pour les nouveaux tests).

### Backlog
- visionOS Spatializer.
- Contacts.framework.
- Continuité cross-device.
- Compression à la volée.
- Chiffrement post-quantique.

---

## 21. Critères d'acceptation globaux

À la fin de chaque phase, **tous** ces critères doivent rester vrais :

| # | Critère | Mesure |
|---|---|---|
| G-1 | Build OK sur 4 configs | `xcodebuild` exit 0 sur iOS+macOS Debug+Release |
| G-2 | Tests OK | `xcodebuild test` exit 0, ≥ 419 tests passants, 0 nouveau fail |
| G-3 | Sécurité crypto intacte | Signatures, anti-replay, TOFU préservés, keyChangedDowngraded préservé |
| G-4 | Performance OK | Débit ≥ 50 Mo/s (Phase 2-bis), `maxInFlightReceive` ≥ 3, throttle 10 Hz |
| G-5 | SHA-256 jamais logué en clair | grep sur les sources |
| G-6 | `print()` réduit à 0 hors `#if DEBUG` | grep sur les sources |
| G-7 | Pas de régression UI | snapshot tests des vues inchangées |
| G-8 | Aucun `sendChunk` mort | grep `maxPipelineDepth` |
| G-9 | `AirBridgeCore.swift` < 800 l. (après phase 7) | wc -l |
| G-10 | Privacy Manifest validé | `xcrun xcprivacy` exit 0 |

---

## 22. Risques du projet

### Risques techniques

| # | Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|---|
| R-1 | Régression de la sécurité crypto pendant l'ajout de features | Faible | Critique | Tests de caractérisation + revue dédiée pour toute modif Security/ |
| R-2 | Régression de performance Phase 2-bis | Moyenne | Élevé | Benchmark CI bloquant + `TransferPerformanceLog` en DEBUG |
| R-3 | God class refactor casse le pipeline | Élevée | Élevé | Refactor par étapes avec tests verts à chaque PR |
| R-4 | Share Extension sandbox bloque un cas | Moyenne | Moyen | Tests E2E obligatoires avant merge |
| R-5 | Live Activity rejette en App Review | Faible | Moyen | Validation App Store Connect dès le sprint 6 |
| R-6 | Background transfer >1 Go échoue sur iOS | Élevée | Élevé | Plafonner à 200 Mo par défaut, proposer "garder app ouverte" |
| R-7 | visionOS Spatializer ne marche pas | Moyenne | Faible | Tester sur xrsimulator dès sprint 0 |
| R-8 | Drag & drop Dock casse sous sandbox | Faible | Moyen | Tester sur App Sandbox activé dès sprint 5 |

### Risques produit

| # | Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|---|
| R-9 | AirDrop-like jamais perçu comme tel | Moyenne | Élevé | Focus sur le radar full-screen + preview (phase 1+2) |
| R-10 | L'utilisateur oublie AirBridge pour AirDrop (Apple) | Élevée | Élevé | Insister sur la sécurité (fingerprint) et le multi-plateforme |
| R-11 | "Contacts Only" est ambigu | Moyenne | Moyen | UX claire : 3 modes étiquetés, exemples |
| R-12 | "Recevoir de tous" en entreprise pose problème | Moyenne | Moyen | Mode "Off" par défaut en profil Managed |

### Risques de dette technique

| # | Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|---|
| R-13 | La dette s'accumule si pas de phase 7 | Élevée | Élevé | Imposer la phase 7 (god class) avant la phase 8 (polish) |
| R-14 | Le `Logger` n'est jamais migré | Moyenne | Moyen | Phase 0 + audit grep dans CI |
| R-15 | Le code mort n'est jamais supprimé | Élevée | Faible | Ajouter lint rule dans CI |

---

## 23. Vision finale AirBridge

> **AirBridge, à terme, est l'AirDrop multiplateforme open-source qui fait confiance à l'utilisateur.**

Les éléments qui font la différence AirDrop :

1. **Le radar plein écran** au lancement, sans tab.
2. **L'auto-popup de pairing** avec un code à 6 chiffres.
3. **La preview des fichiers** avant envoi / réception.
4. **Le mode "review and send"** entre file picker et démarrage.
5. **Le mode "Contacts Only"** comme défaut.
6. **Le drag & drop sur l'icône Dock** + l'entrée dans la feuille de partage système.
7. **Le son distinctif** + le haptique triple à la complétion.
8. **La Live Activity** + le background transfer.
9. **L'identité claire** : "AirBridge" est l'AirDrop qui ne te trahit pas, ne t'envoie pas de pub, et fonctionne sur n'importe quel device Apple.

**L'architecture actuelle est déjà 80 % de la route.** Les phases 0 à 6 sont des **wires et des features**, pas des changements de fondations. La sécurité est préservée à chaque étape.

**L'ingrédient manquant** est l'**engagement produit** : quelqu'un doit décider que AirBridge est plus qu'un POC, et le pousser jusqu'à l'App Store avec un focus utilisateur.

---

## LES 10 PROCHAINES ACTIONS EXACTES

> L'ordre ci-dessous est **strict** : chaque action préserve l'invariant de l'étape précédente. Aucun raccourci sur la sécurité.

### 1. **Supprimer la notification de test au démarrage** (30 min)
- Fichier : `AirBridge/AirBridgeApp.swift`, lignes 90-100
- Retirer le `Task { @MainActor in try? await Task.sleep(...); manager.notifyTransferCompleted(...) }`.
- **Critère** : plus de notification "1 fichier reçu depuis Test Appareil" au lancement.

### 2. **Supprimer le SHA-256 logué en clair** (1 h)
- Fichier : `Core/AirBridgeCore.swift`, lignes 1368, 2788-2789
- Retirer les `print("🔐 SHA-256 source")`, `print("🔐 SHA-256 annoncé")`, `print("🔐 SHA-256 reçu")` ou les garder en `#if DEBUG`.
- **Critère** : grep `🔐 SHA-256` sur les sources ne renvoie rien hors `#if DEBUG`.

### 3. **Déplacer la permission notifications au 1er envoi/accept** (1 j)
- Fichier : `AirBridge/AirBridgeApp.swift:80-88`
- Retirer la demande du `init()`. La déclencher depuis `ShareViewModel.send(to:)` et `TransferViewModel.acceptPending()`.
- **Critère** : un fresh install ne montre pas la pop-up "AirBridge souhaite vous envoyer des notifications" au 1er lancement.

### 4. **Brancher `PairingConfirmationView` en auto-popup** (1 j)
- Fichier : `UI/MainView.swift`
- Ajouter `@State var presentedPairing: PairingPresentation?` + `.sheet(item:)` qui présente `PairingConfirmationView(core: core)`.
- `onChange(of: core.pairingStore.currentPeerNeedsPairing)` pilote la présentation.
- **Critère** : un pair non-appairé déclenche la sheet dans la seconde qui suit la connexion.

### 5. **Brancher `ShareView` dans la navigation (review-and-send)** (2 j)
- Fichier : `Features/Discovery/DiscoveryView.swift`
- Le bouton "Choisir" ouvre le file picker **puis** présente `ShareView` en sheet (et non `core.importAndRequestItems` directement).
- **Critère** : après sélection de fichiers, l'utilisateur voit un écran de review avec previews et bouton "Envoyer".

### 6. **Ajouter des thumbnails dans `TransferRequestSheet`** (2 j)
- Fichier : `Features/Transfer/TransferRequestSheet.swift`
- Créer `Features/Common/ThumbnailLoader.swift` (actor).
- Utiliser `QLThumbnailGenerator` (iOS) / `QuickLookThumbnailing` (macOS) pour image/vidéo/PDF.
- **Critère** : un JPEG entrant montre un thumbnail 100×100 dans la sheet.

### 7. **Ajouter le mode de visibilité (Everyone / Contacts Only / Off)** (3 j)
- Fichier : `UI/Settings/SettingsView.swift` + `Discovery/BonjourService.swift`
- `@AppStorage("airbridge.visibility")` consomme une enum.
- `BonjourService` lit la valeur au démarrage et configure `NWListener` / `NWBrowser` en conséquence.
- **Critère** : "Off" coupe la découverte et le broadcast.

### 8. **Remplacer `print()` par `os_log`/`Logger`** (3 j)
- Fichiers : tous (327 occurrences).
- Stratégie : introduire un `Log` enum (`Log.core`, `Log.network`, `Log.transfer`, etc.) avec `os_log` en Release, `print` en DEBUG.
- Garde `#if DEBUG` sur les chemins sensibles.
- **Critère** : grep `print(` ne renvoie que des occurrences sous `#if DEBUG` ou dans `Log` enum.

### 9. **Créer la cible Share Extension** (1 semaine)
- Nouvelle cible `.appex` dans `project.pbxproj`.
- `ShareViewController.swift` SwiftUI basique.
- App Group `group.com.airbridge.shared` + `SharedTransferQueue` actor.
- **Critère** : "AirBridge" apparaît dans la feuille de partage système et peut recevoir un fichier.

### 10. **Découper `AirBridgeCore` (god class) — Phase 1** (1 semaine)
- Extraire `PairingOrchestrator` (400 l.) et `SessionOrchestrator` (500 l.) depuis `AirBridgeCore.swift`.
- Tests de caractérisation avant / tests verts après.
- **Critère** : `AirBridgeCore.swift` < 2 500 l. (étape 1), aucun orchestrateur > 800 l., 419 tests passent.

**Effort total estimé pour ces 10 actions** : ~3-4 semaines pour 1 développeur à temps plein.
**Gain utilisateur** : passage de "partage manuel" à "transfert magique".

---

## RECOMMANDATION FINALE

> **Stratégie recommandée : « Connecter ce qui existe »**, pas « tout réécrire ».

L'architecture d'AirBridge est techniquement saine au niveau des briques individuelles :
- **Sécurité** : P-256 Keychain, ECDH éphémère, ChaCha20-Poly1305, anti-replay, TOFU, keyChangedDowngraded, self-pairing bloqué. **C'est prêt pour la production.**
- **Pipeline** : `pipelineDepth=4`, `ChunkSink` actor, `IncomingFileWriter` nonisolated, `OutgoingTransferManager.sendChunkOverConnectionStatic` static nonisolated. **Phase 2-bis est complète.**
- **Reprise** : `ResumePersistence` actor, `scheduleAutomaticResumeOnReconnect`, `IncomingFileWriter` tronque si trop long. **Prêt pour la production.**

**Le déficit est dans la surface produit** : l'UI traite AirBridge comme « application de préférences + sélecteur de fichier » plutôt que comme « transfert magique instantané ». Le problème n'est pas architectural — il est **UX** et **wiring**.

### Pourquoi cette stratégie

1. **Préservation totale** de l'architecture sécurité et pipeline. Aucun risque de régression crypto.
2. **Gains rapides** : 4 des 10 actions sont des quick wins (1 j ou moins chacune). Le ratio gain/effort est maximal.
3. **Pas de migration risquée** : les phases s'enchaînent, chacune ajoutant une couche sans toucher aux précédentes.
4. **Conforme à l'ADN AirDrop** : radar plein écran + auto-popup de pairing + review-and-send + preview = c'est exactement ce qui distingue AirDrop d'un sélecteur de fichier.
5. **Préserve la philosophie d'AirBridge** : pas de compte utilisateur, pas de cloud, fingerprint humain, sécurité vérifiable.

### Pourquoi pas les autres stratégies

- **« Tout réécrire »** (refactor god class d'abord) : prend 2-3 semaines sans bénéfice utilisateur, risque de régression crypto sur le chemin critique.
- **« Faire un fork d'AirDrop-like »** : impossible, c'est dans le système Apple.
- **« Se positionner comme alternative cloud-first »** : sort de l'ADN du projet (LAN-only, P2P, zéro serveur).
- **« Ajouter de la compression / post-quantique »** : nice-to-have, mais l'utilisateur n'en voit rien tant que le radar n'est pas plein écran.

### Feuille de route

| Sprint | Durée | Action principale | Bénéfice |
|---|---|---|---|
| 0 | 1-2 j | Quick wins sécurité & UX (actions 1-3) | App perçue comme « propre » |
| 1 | 1 sem | Brancher les vues orphelines (actions 4-5) | UX AirDrop-like commence à apparaître |
| 2 | 1 sem | Preview + visibilité + device name (actions 6-7) | Utilisateur voit ce qu'il envoie |
| 3 | 1 sem | Logs propres + CI (action 8) | Hygiène + confiance |
| 4 | 1 sem | Share Extension (action 9) | AirBridge dans la feuille système |
| 5 | 1 sem | God class refactor phase 1 (action 10) | Maintenabilité long terme |

**À la fin de la semaine 6** : AirBridge est **prêt pour TestFlight** et un beta public.
**À la fin du trimestre** : AirBridge est **prêt pour l'App Store** (avec phases 6 Live Activity + 8 polish + 9 CI).

### Verdict final

> **AirBridge est à 80 % de la route vers AirDrop.** Les fondations sont solides. Les 20 % manquants sont du **wiring** (vues orphelines) et du **polish** (preview, haptique, son, branding). Avec ~6 semaines de travail discipliné, AirBridge peut prétendre à l'**équivalent AirDrop sur l'écosystème Apple** — sans serveur, sans compte, sans cloud, et avec une **sécurité vérifiable** qu'AirDrop lui-même n'expose pas (fingerprint humain).
>
> **L'erreur stratégique à éviter** : se lancer dans un grand refactor du Core avant d'avoir branché les vues orphelines. L'utilisateur ne verra jamais la différence entre un Core de 3491 l. et un Core de 800 l. — mais il verra la différence entre un radar plein écran avec preview et un radar tabé avec une icône générique.

---

## ANNEXE — Inventaire des 4 agents d'audit

| Agent | Spécialité | Verdict |
|---|---|---|
| Architecture & organisation | Découpage, dette, fuites conceptuelles | ⚠️ God class + code mort + fuites (3-5) |
| UX/UI & gap AirDrop | Écrans, flux, manques AirDrop | 🟡 9 gaps hauts, 9 moyens, 4 bas |
| Tests & scénarios | Couverture, E2E, lifecycle | ⚠️ Fort sur crypto, faible sur UI/lifecycle |
| Fiabilité/sécurité/performance | Crypto, reprise, logs, perf | ✅ Crypto intact, ❌ 1 leak SHA-256, ⚠️ 327 prints |

Les rapports détaillés de chaque agent sont disponibles dans les fichiers de sortie d'agent.
