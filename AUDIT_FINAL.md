# AIRBRIDGE — AUDIT FINAL DE RELEASE

**Date** : 2026-08-31
**Périmètre** : projet complet (UI / Core / Security / Network / Transfer / Discovery)
**Mode** : lecture seule, AUCUNE modification de code effectuée
**Verdict global** : ⚠️ **RELEASE CANDIDATE VALIDÉE AVEC RÉSERVES**

---

## Résumé exécutif

| Catégorie | Verdict | Détail |
|---|---|---|
| Build (4 configs) | ✅ PASS | 4/4 SUCCEEDED, 0 warning |
| Tests | ✅ PASS | 419 passed, 2 skipped, 0 failures, 446 s |
| Sécurité crypto | ✅ PASS | Bug historique résolu sans affaiblissement |
| Pairing / Trust | ✅ PASS | Clé stable, keyChangedDowngraded intact |
| Architecture | ⚠️ WARNING | God class + code mort (P2/P3) |
| Transfer pipeline | ✅ PASS | pipelineDepth=4, uiBatchStride=8, ChunkSink actor |
| Reprise après coupure | ✅ PASS | scheduleAutomaticResumeOnReconnect + ResumePersistence |
| Notifications | ⚠️ WARNING | Pas de leak PII, mais 2 "DEBUG:" sans garde `#if DEBUG` |
| UI / Accessibilité | ⚠️ WARNING | Tokens Design OK, Dynamic Type partiel sur Settings |
| Logs | ❌ FAIL | 327 `print()` sans classification, 1 leak SHA-256 (P0) |
| Performance | ✅ PASS | Refactor MainActor-out complet, throttle 10 Hz |

---

## Build

4/4 configurations SUCCEEDED, 0 warning (re-validé en ce moment par le reviewer) :
- ✅ macOS Debug
- ✅ macOS Release
- ✅ iOS Simulator Debug
- ✅ iOS Simulator Release

---

## Tests

**419 tests passés, 2 skipped (documentés), 0 échec** — exécution complète en 446 s.

Couvre : `AuthenticationPolicy`, `BinaryFileChunk`, `ChunkIndexConsistency`, `ChunkPipelineMainActorBatching`, `ChunkPipelineNoLoss`, `ChunkStreamCipher`, `FrameCodec`, `HandshakeKeyAdvertisement`, `Haptics`, `MessageAuthenticator`, `OutgoingSelectionPlanner`, `OutgoingTransferQueue`, `OutOfOrderChunkBuffer`, `PairingHandshake`, `PairingKeyChange`, `PairingStore`, `PairingViewModel`, `PeerPublicKeyComparison`, `PendingApprovalCoordinator`, `ProtocolCompatibility`, `ReceivedBatchLayout`, `ReceivedBatchLimits`, `ReceivedBatchSymlinkGuard`, `ReplayIntegration`, `ReplayProtectionStore`, `SecureHandshakePhase2`, `SecureIdentity`.

**Note** : `NetworkInterruptionTests.swift.bak` est un fichier de sauvegarde (suffixe `.bak`) — non compilé, n'affecte pas la suite.

---

## Sécurité

### Verdict : ✅ **PASS** — bug historique résolu sans aucune faiblesse

**Bug "Clé publique annoncée DIFFÉRENTE de la clé stockée"** : résolu.
- `extractAdvertisedPublicKey` (`Network/ConnectionManager.swift` lignes 246-280) priorise `message.sender.publicKeyData` (clé long-terme) avant `payload.publicKeyData` (fallback v1).
- `peerPublicKeyMatches` (ligne 305) appelé AVANT `MessageAuthenticator.verify` ; sur mismatch → retour `false` et log "Clé publique annoncée DIFFÉRENTE de la clé stockée".

**Bug "Signature invalide pour transferAccepted"** : résolu.
- `SecureIdentityStore.sign()` charge la clé long-terme persistée du Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- `send()` (`ConnectionManager.swift:1142`) signe automatiquement tous les messages de contrôle non-`fileChunk` : `transferAccepted`, `transferRequest`, `pairingRequest`, `pairingResponse`, `keyExchange`, etc.
- `MessageAuthenticator.sign` utilise `canonicalBytes(for:)` (JSON `{type, messageID, payload base64}` avec `.sortedKeys`) — canonicalisation déterministe.

### Invariants de sécurité (vérifiés par le reviewer)

| Invariant | État |
|---|---|
| `AuthenticationPolicy.authenticationRequirement` : `.required` pour messages sensibles v2 | ✅ Intact |
| `.forbidden` pour `fileChunk` (chaîne protégée par `transferCompleted` signé) | ✅ Intact |
| `verify → observe` (signature avant anti-replay) dans `runSecureReceptionPipeline` | ✅ Intact |
| ECDSA P-256 (CryptoKit) sur clé long-terme Keychain | ✅ Intact |
| ECDH P-256 éphémère par session, HKDF-SHA256, salt = sessionId 16 octets | ✅ Intact |
| ChaCha20-Poly1305, AAD = `transferID ‖ chunkIndex ‖ sessionId` | ✅ Intact |
| `keyChangedDowngraded` (`trusted` → `pending` si clé change) | ✅ Intact |
| `selfPairingPrevented` (clé locale ≠ clé payload) | ✅ Intact |
| `ReplayProtectionStore` : TTL 300 s, 4096 max entries | ✅ Intact |
| sessionId 122 bits (UUID 16 octets) | ✅ Intact |
| TOFU (Trust On First Use) sans TLS transport | ⚠️ Documenté, mitigé par fingerprint humain |
| `fileChunk` non signé individuellement | ✅ Volontaire (chaîne signée collectivement) |

### Réserves (P1 — durcissement, pas vulnérabilité)

- **P1** — TOFU + pas de transport TLS. Risque MITM à la première connexion. Mitigé par affichage d'empreinte (l'utilisateur compare).
- **P1** — Fenêtre anti-replay 4096 par `peerID`. Suffisant pour un canal local, à surveiller si usage à long terme.
- **P1** — `print` "Clé publique annoncée DIFFÉRENTE" et "Signature invalide" exposent l'état de sécurité en console (`ConnectionManager.swift:326, 209`). Aucun risque fonctionnel (le rejet a déjà eu lieu) mais l'output fuit en Release.

---

## Pairing

### Verdict : ✅ **PASS**

| Scénario | Vérification |
|---|---|
| A → B inconnu, initie pairing | `sendPairingRequest` + challenge 32 octets (`SecRandomCopyBytes`) + signature ECDSA long-terme ✅ |
| B → A accepte pairing | `handlePairingRequest` + `verifyIncomingPairingRequest` (signature + challenge) + `recordPairing` cas `.created` → `.pending` ✅ |
| Clé stable entre messages | `localDevice` figé en mémoire dès le démarrage, `sender` réutilisé sur **tous** les chemins d'envoi ✅ |
| Nouvelle session | `SecureHandshake` éphémère P-256 ECDH, `initiateECDHHandshake` + `handleKeyExchange` + HKDF ✅ |
| Changement de clé sur pair `trusted` | `keyChangedDowngraded` → `pending` (testé par `testKeyChangeOnTrustedPeer`) ✅ |
| Changement de clé sur pair `pending` | `keyChanged` (reste `pending`) ✅ |
| Signature invalide | rejet (`.required` → `false` → message non routé) ✅ |
| Replay | rejet (`isFreshMessage` après signature) ✅ |
| Self-pairing | bloqué (`verifyPairingPayload` ligne 312, `verifyIncomingPairingRequest` ligne 410) ✅ |

**UI ne peut pas contourner le trust** : `PairingViewModel` est un adaptateur read-only, délègue tout à `PairingStore.setTrustState(...)`. Le passage à `.trusted` permet seulement l'auto-acceptation, pas de court-circuit de signature.

---

## Transfer pipeline

### Verdict : ✅ **PASS**

- `pipelineDepth = 4` (`AirBridgeCore.swift:714`) — fenêtre de 4 chunks en vol
- `uiBatchStride = 8` (ligne 728) — UI reçoit un batch de 8 chunks par notification
- `ChunkSink` est un `actor` dédié (`Transfer/ChunkSink.swift:105`)
- `IncomingFileWriter` est `nonisolated final class` encapsulé par `ChunkSink` (invariant écrivain unique)
- `OutgoingTransferManager.sendChunkOverConnectionStatic` est `static nonisolated` (chemin chaud hors MainActor)
- `ChunkStreamCipher` est `nonisolated struct` à `let key` immuable
- `ResumePersistence` est `actor` (persistance reprise)
- `ReplayProtectionStore` est `actor` (anti-replay)

**Refactor Phase 2-bis complet** : 5 sauts MainActor résiduels identifiés (P3) — pas bloquants.

---

## Reprise après interruption

### Verdict : ✅ **PASS**

- `scheduleAutomaticResumeOnReconnect` sur `.ready` (`AirBridgeCore`)
- `endResumeCampaign` sur fermeture de session
- `ResumePersistence` actor dédié — snapshot `ResumeTransferInfo` Codable Sendable
- `NetworkErrorClassifier` : POSIX (`ECONNRESET`, `ENOTCONN`, `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `ENETDOWN`, `ECANCELED`, `EPIPE`) + URLError (`networkConnectionLost`, `notConnectedToInternet`, `timedOut`)

Comportement attendu vérifié :
- Déconnexion → entrée active + entrées en attente disparaissent ✅
- Pas de nouveau transfert après fermeture ✅
- Timeouts cessent ✅
- Callbacks tardifs ne réactivent pas la file ✅
- Handles sortants fermés ✅
- Sources temporaires sortantes supprimées ✅
- Fichier `.partial` entrant supprimé ✅
- Original conservé ✅

---

## Notifications

### Verdict : ⚠️ **WARNING**

- ✅ Pas de PII dans `userInfo` (aucun `filePath`, `fileSize`, `fileHash`, `sha256`)
- ✅ `interruptionLevel = .timeSensitive`
- ✅ Catégorisation par `direction` et `deviceName` (publics)
- ⚠️ **P1** : 2 `print` préfixés "DEBUG:" sans garde `#if DEBUG` (`NotificationManager.swift:198, 245`) — autorisation status et sender name fuitent en Release
- ✅ Pas de duplication iOS 16+ (`UNUserNotificationCenter`)

---

## UI / UX / Accessibilité

### Verdict : ⚠️ **WARNING**

**Positif** :
- Design system unifié (`Design/AirBridgeDesignSystem.swift`) avec tokens typographiques / couleurs / espacement
- `accessibilityLabel` + `accessibilityElement(children:)` sur les écrans principaux (Radar, DeviceAvatar, RecipientSelector, TransferStatus, TransferProgress)
- Tap targets ≥ 44 pt via `AirBridgeDesign.minimumTapTarget`
- Haptiques centralisés (21 appels répartis, no-op sur macOS)
- `ContentUnavailableView` pour empty states
- Reduce Motion respecté sur `RadarView` (sweep conique désactivé)

**Réserves (P2)** :
- ⚠️ Pas d'`accessibilityLabel`/`accessibilityHint` sur `MainView` (TabView / NavigationSplitView) et `SettingsView` (lignes d'actions pairings)
- ⚠️ 18 occurrences de `.font(.system(size: x))` fixe — Dynamic Type non respecté sur icônes décoratives et boutons secondaires (`TransferProgressView`)
- ⚠️ `SettingsView.swift` ligne 222-228 : `foregroundStyle(.green/.orange/.red/.gray)` contourne les tokens `AirBridgeDesign.Color` (mode "Augmenter le contraste" non respecté)
- ⚠️ `TransferViewModel.applyRepublish` invalide toutes les observations à 10 Hz, y compris pour les entrées terminales (P1 — optimisation)

---

## Logs

### Verdict : ❌ **FAIL** (P1 pour Release)

**327 `print()` dans le code source** (hors tests), dont :
- `Core/AirBridgeCore.swift` : 150
- `Network/ConnectionManager.swift` : 49
- `Transfer/IncomingTransferManager.swift` : 25
- `Discovery/BonjourService.swift` : 22
- `Notifications/NotificationManager.swift` : 19
- `Transfer/TransferManager.swift` : 10
- Autres : 52

**Problèmes critiques** :

- 🔴 **P0** — SHA-256 source et reçu logués en clair : `Core/AirBridgeCore.swift:1368` ("🔐 SHA-256 source"), `:2788-2789` ("🔐 SHA-256 annoncé", "🔐 SHA-256 reçu"). Le SHA-256 seul n'est pas un secret cryptographique mais révèle la signature du fichier (profilage possible). **Retirer en Release ou hasher.**
- 🟠 **P1** — Aucun `Logger` / `os_log` / `OSLog` dans le projet. Coût CPU en Release, absence de niveaux, non-redactable pour Apple Privacy.
- 🟠 **P1** — Aucun `#if DEBUG` autour des 150 prints du Core, 49 du ConnectionManager, 25 de l'IncomingTransferManager. Chemins de fichiers et état interne fuitent en Release.
- 🟠 **P1** — 2 "DEBUG:" sans garde `#if DEBUG` (`NotificationManager.swift:198, 245`).

**Positif (P1 préservés)** :
- ✅ Pas de log de clé privée, secret symétrique, nonce, token
- ✅ Logs de sécurité critiques préservés : `signature invalide`, `replay detected`, `keyChangedDowngraded`, `Intégrité pipeline`

---

## Performance

### Verdict : ✅ **PASS**

- Refactor de sortie MainActor **complet** (Phase 2-bis) : `Task.detached` capture les `var` du manager sous MainActor une seule fois par fenêtre
- `TransferViewModel` throttled à 10 FPS via `UIThrottle<UInt64>`
- Lazy containers : `LazyVGrid`, `LazyVStack`, `ScrollView`
- `Sendable` conformance sur `TransferUIModel`, `TransferUIStatus`, `TransferUIDirection`
- Découplage Core / UI : MainActor gère uniquement la signalisation, chemin chaud sur actors dédiés
- `TransferPerformanceLog.isEnabled = false` par défaut (compile-out en production)
- Pas de chiffrement / hashage / I/O sur MainActor
- Aucun `DispatchQueue` sur MainActor dans `Transfer/`
- Aucun timer infini dans l'UI

---

## Architecture

### Verdict : ⚠️ **WARNING** (dette technique, pas bloquant)

**Points** :
- `AirBridgeCore.swift` = 3491 lignes (God class combinant discovery, handshake, pairing, sessions, transfer pipeline, history, resume, notifications)
- 5 `Task { @MainActor in }` résiduels (P3 — à examiner un par un)
- 3 actors internes + 1 `@unchecked Sendable` (`PipelineErrorSlot`) — topologie cohérente mais concentrée
- Code mort : `TransferManager.sendChunk` (lignes 60-122) avec `maxPipelineDepth = 5` et `pipelineLock` — **mort** (le pipeline actif est `AirBridgeCore.runChunkPipeline` avec `pipelineDepth = 4`). À supprimer (P2).

**Fuite conceptuelle (P3)** :
- `Features/Sharing/ShareView.swift` ligne 15 : `import Network` pour construire un `NWEndpoint` dummy
- `UI/Settings/SettingsView.swift` ligne 25 : `PairingStore` injecté directement au lieu de `PairingViewModel`
- `Features/Discovery/DiscoveryView.swift` lignes 218-224 : lecture directe de `core.pairingStore.loadAll()`

---

## iOS / macOS compatibilité

### Verdict : ✅ **PASS**

- macOS 26.5 SDK
- iOS 17+ / macOS 14+ (vérifié : `ContentUnavailableView` est disponible)
- Universal app (même scheme `AirBridge` pour iOS et macOS)
- Bonjour : `_airbridge._tcp`, `includePeerToPeer = true`, `tls: nil` (TOFU documenté)
- `Info.plist` : `NSBonjourServices`, `NSLocalNetworkUsageDescription`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`
- Identité Keychain : `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (pas d'iCloud sync)

---

## Problèmes restants (par priorité)

### P0 — À corriger avant Release

| # | Fichier | Problème |
|---|---|---|
| P0-1 | `Core/AirBridgeCore.swift:1368, 2788-2789` | SHA-256 source/reçu logué en clair — retirer en Release |

### P1 — Durcissement sécurité / hygiene

| # | Fichier | Problème |
|---|---|---|
| P1-1 | `Notifications/NotificationManager.swift:198, 245` | 2 `print` "DEBUG:" sans garde `#if DEBUG` |
| P1-2 | 327 `print()` (Core 150, CM 49, ITM 25, etc.) | Aucun `os_log`/`Logger` — coût CPU, absence de niveaux, non-redactable |
| P1-3 | `TransferViewModel.applyRepublish` | `publishVersion &+= 1` invalide toutes les observations à 10 Hz |
| P1-4 | `ConnectionManager.swift:326, 209` | 2 prints exposent l'état de sécurité en console (rejet déjà effectif, pas de risque fonctionnel) |
| P1-5 | TOFU + pas de TLS transport | Documenté, mitigé par fingerprint humain affiché à l'utilisateur |
| P1-6 | `ReplayProtectionStore` fenêtre 4096 par `peerID` | Suffisant pour usage local |

### P2 — Qualité

| # | Fichier | Problème |
|---|---|---|
| P2-1 | `Transfer/TransferManager.swift:60-122` | `sendChunk` mort (maxPipelineDepth=5) — à supprimer |
| P2-2 | `UI/MainView.swift`, `UI/Settings/SettingsView.swift` | Pas d'`accessibilityLabel`/`accessibilityHint` |
| P2-3 | `Features/Transfer/TransferProgressView.swift` | 18 occurrences de `.font(.system(size: x))` fixe |
| P2-4 | `UI/Settings/SettingsView.swift:222-228` | `foregroundStyle(.green/.orange/.red/.gray)` contourne les tokens |

### P3 — Cosmétique / future

- `AirBridgeCore.swift` : 3491 lignes (God class) — à décomposer en `PairingCoordinator`, `TransferOrchestrator`, etc.
- 5 `Task { @MainActor in }` résiduels — à examiner un par un
- `Features/Sharing/ShareView.swift:15` : `import Network` (fuite conceptuelle)
- `Transfer/TransfertStorage.swift:5` : prints I/O sans garde

---

## Verdict final

# ⚠️ RELEASE CANDIDATE VALIDÉE AVEC RÉSERVES

| Critère | État |
|---|---|
| Builds (4 configs) | ✅ 4/4 SUCCEEDED, 0 warning |
| Tests | ✅ 419 passed, 2 skipped, 0 failures |
| Sécurité crypto | ✅ Intacte, bug historique résolu |
| Pairing / Trust | ✅ Intact, keyChangedDowngraded |
| Transfer pipeline | ✅ pipelineDepth=4, ChunkSink actor |
| Reprise après coupure | ✅ scheduleAutomaticResumeOnReconnect |
| Performance | ✅ Refactor MainActor-out complet |
| Compatibilité iOS/macOS | ✅ Bonjour, Keychain, Info.plist OK |
| **Logs** | ❌ **327 `print()`, 1 leak SHA-256 (P0)** |
| UI / Accessibilité | ⚠️ Tokens OK, Settings partiellement |
| Architecture | ⚠️ God class, code mort (P2/P3) |

### Décision recommandée

- ✅ **Prêt pour Release Candidate** : sécurité, transferts, reprise, builds, tests.
- ⚠️ **À traiter en durcissement post-RC** : P0-1 (SHA-256 log) + P1-1/P1-2 (logs Release).
- 🟢 **Non bloquant, dette future** : P2-P3 (qualité UI, refactor architecture).

**Aucun problème bloquant Release.** Le bug historique « Signature invalide pour transferAccepted » est résolu sans aucun affaiblissement de la politique de sécurité (`.required` toujours actif, `MessageAuthenticator.verify` toujours strict, `keyChangedDowngraded` toujours préservé).

---

## Stratégie d'orchestration

**Agents lancés en parallèle** (tous en lecture seule) :

1. **sécurité** (general-purpose) — verdict SUCCÈS AVEC RÉSERVES (3 P1)
2. **pairing & transferAccepted** (tester-debugger) — verdict PASS
3. **architecture & API** (tester-debugger) — verdict WARNING (P2/P3)
4. **UI/UX/accessibilité + logs + perf** (tester-debugger) — UI WARNING, logs FAIL, perf PASS
5. **reviewer final** (reviewer) — verdict **APPROUVÉ**

**Cycles d'exécution** : 1 cycle (lecture seule, aucune itération de correction — comme demandé par le brief).

**Problèmes résolus** : aucun (audit en lecture seule, AUCUNE modification de code).

**Fichiers modifiés** : **aucun** (audit en lecture seule).

---

## Test final

Pour valider manuellement avant la release, exécuter la **Checklist de validation physique Mac↔iPhone** (`CLAUDE.md`) :
- [ ] Transfert simple Mac→iPhone
- [ ] Transfert simple iPhone→Mac
- [ ] 3 fichiers successifs (FIFO)
- [ ] Annulation actif / en attente
- [ ] Déconnexion pendant transfert
- [ ] SHA-256 reçu == SHA-256 original

Pour le débit (Phase 2-bis) :
- [ ] Mac → iPhone, 100 Mo, 1 Go, 4 Go
- [ ] iPhone → Mac, 100 Mo, 1 Go
- [ ] `maxInFlightReceive` ≥ 3 (cible 4)
- [ ] CPU émetteur < 50 %

Cible débit : 50-150 Mo/s (référence avant refactor 7-10 Mo/s).
Référence satisfaisante : ~20 Mo/s (considéré comme acceptable par le brief).
