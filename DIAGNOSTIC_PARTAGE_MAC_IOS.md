# 🔧 AIRBRIDGE — TRANSFERT MAC → iPHONE BLOQUÉ SUR « EN ATTENTE »

**Date** : 2026-09-21
**Symptôme rapporté** : le Mac envoie un fichier à l'iPhone, la réception est **acceptée sur l'iPhone**, mais l'émetteur reste indéfiniment sur « En attente » — aucun octet ne part.
**Périmètre** : `Core`, `Network`, `Discovery`, `Transfer`, `UI/Settings`, `Features/Diagnostics`, `Tests`
**Verdict** : 🔴 **5 défauts de la chaîne d'acceptation — corrigés** + 🟢 **panneau de diagnostic ajouté** (Réglages ▸ « Diagnostic du partage »)
**Sécurité** : ✅ **aucune protection affaiblie** (identité P-256, ECDH, ChaCha20-Poly1305, anti-rejeu, pairage TOFU intacts — la politique d'authentification n'a pas été touchée)

---

## 1. Ce que « En attente » veut dire dans le code

« En attente » n'est pas un état d'attente générique : c'est le libellé exact d'un état de transfert.

```swift
// Transfer/Transfer.swift — Transfer.State.displayName
case .requesting:          "Préparation"
case .waitingForApproval:  "En attente"     // ← le symptôme
case .accepted:            "Accepté"
case .transferring:        "En cours"
```

Côté **émetteur**, l'état `.waitingForApproval` est posé par
`AirBridgeCore.sendApprovalRequestIfNeeded` juste avant l'envoi du
`transferRequest`, et **ne peut être quitté que par** :

| Événement | Effet |
|---|---|
| `transferAccepted` reçu et routable | `.accepted` puis `beginOutgoingTransfer` → `.transferring` |
| `transferRejected` reçu | `.rejected` (terminal) |
| Délai d'approbation (300 s) | échec explicite |
| Fermeture de session | `.interrupted` (reprisable) |

Le blocage rapporté est donc **toujours** l'un de ces deux faits :

1. le `transferAccepted` de l'iPhone **n'est jamais parti** ;
2. il est parti mais a été **écarté à la réception** sur le Mac, ou son
   traitement a **échoué en silence**.

Les cinq défauts ci-dessous couvrent ces deux branches — et une troisième,
annexe mais réelle : une réception interrompue qui **ressuscitait** en
« En cours » et devenait impossible à reprendre.

---

## 2. Les cinq défauts (cause racine)

### Défaut A — le récepteur ignorait l'échec d'envoi de son acceptation

`AirBridgeCore.acceptPendingTransfer()` appelait
`connectionManager.sendTransferAccepted(...)` **sans examiner le `Bool`
renvoyé**. Or ce renvoi échoue dès que la connexion de contrôle n'est pas
résolvable (session en cours de bascule, `NWConnection` déjà `.cancelled`,
handshake ECDH pas terminé) :

```swift
// Network/ConnectionManager.swift
func sendTransferAccepted(transferID: UUID, on connection: NWConnection) -> Bool {
    guard let controlConnection = resolveControlConnection(preferred: connection) else {
        return false      // ← personne ne regardait cette valeur
    }
    ...
}
```

**Résultat** : l'iPhone affichait « Accepté », l'utilisateur croyait le
transfert lancé, et le Mac restait « En attente » sans aucun délai armé
côté réception.

**Correctif** : envoi d'abord, état ensuite. Si le renvoi échoue, le
transfert passe en `.failed` avec un motif explicite
(« Acceptation non transmise à l'émetteur »), le writer est fermé, et
l'utilisateur est prévenu — au lieu d'un « Accepté » mensonger. Le même
traitement est appliqué à l'auto-acceptation des pairs de confiance.
Les deux points d'appel (`acceptPendingTransfer` et l'auto-acceptation des
pairs de confiance) examinent désormais le `Bool` renvoyé — il n'existe
plus aucun chemin où une acceptation est marquée localement sans avoir été
transmise. `sendTransferAccepted` /
`sendTransferRejected` disposent en plus d'une variante sans connexion
explicite qui retombe sur la session vivante
(`resolveControlConnection(preferred: nil)`), ce qui couvre le cas d'une
acceptation déclenchée hors du contexte de la demande (relance, reprise).

### Défaut B — l'acceptation reçue annulait le délai *avant* de démarrer l'envoi

Le handler `.transferAccepted` du Mac annulait le timeout d'activité,
**puis** appelait `beginOutgoingTransfer(entry)`, dont toutes les gardes
sortaient en `return` silencieux :

```swift
// Core/AirBridgeCore.swift — AVANT
private func beginOutgoingTransfer(_ entry: OutgoingTransferQueue.Entry) {
    guard connectionManager.isSecureSessionReady,
          connectionManager.connectedDevice?.id == entry.peer.id,
          outgoingTransferQueue.isActive(entry.id),
          approvedOutgoingTransfers.contains(entry.id),
          startedOutgoingTransfers.insert(entry.id).inserted else {
        return          // ← 5 causes possibles, aucun log, aucun délai, aucun échec
    }
    ...
}
```

**Résultat** : plus aucun délai actif, aucun démarrage, aucun échec —
« En attente » **pour toujours**. C'est le cœur du blocage rapporté.

**Correctif** : `beginOutgoingTransfer` renvoie désormais une issue
explicite, et l'appelant en tire les conséquences.

```swift
nonisolated enum OutgoingStartOutcome: Equatable {
    case started              // les chunks partent
    case alreadyRunning       // déjà en cours, rien à faire
    case finishedInError      // échec terminal déjà traité
    case deferred(reason: String)  // pas encore possible → délai obligatoire
}
```

Sur `.deferred`, `armAcceptedStartTimeout` arme un délai de
**20 s** (`acceptedStartGracePeriod`) : à l'expiration, une dernière
tentative est faite, puis le transfert **échoue avec un motif explicite et
le pair est prévenu**. Court volontairement — à ce stade le destinataire a
déjà dit oui, l'utilisateur attend un démarrage immédiat, pas les 300 s du
délai d'approbation.

Les **trois** points de démarrage d'un envoi traitent désormais cette issue
(`markOutgoingTransferApproved` à la réception du `transferAccepted`,
`activateOutgoingTransfer` quand une entrée acceptée arrive en tête de la
file FIFO, et la relance du délai lui-même), et `beginOutgoingTransfer`
n'est **plus** `@discardableResult` : un futur appelant qui ignorerait
l'issue ne compilerait plus silencieusement. `failOutgoingTransfer`
enregistre aussi le motif sur le transfert (`errorMessage`), pas seulement
dans le message envoyé au pair.

Enfin, `recoverOrphanedApprovedTransfer` rattrape le cas d'un transfert
approuvé dont l'entrée a disparu de la file : il passe à `.interrupted`
(reprisable) au lieu de rester affiché « En attente » alors que plus rien
ne peut le démarrer.

### Défaut C — course entre annonce et pairage : l'acceptation était écartée

`AuthenticationPolicy` exige une clé long-terme **enregistrée** pour
authentifier un contrôle sensible comme `transferAccepted`. Annoncer un
transfert (`transferRequest`) avant la fin du pairage produisait donc
exactement le symptôme : le destinataire accepte, son acceptation est
**écartée par le pipeline de réception sécurisé** du Mac (signature
invérifiable faute de clé persistée), et l'émetteur reste « En attente ».

Le rejet était de plus **totalement silencieux** pour l'utilisateur : seul
`Console.app` en gardait la trace.

**Correctif** (trois volets) :

1. **Barrière de pairage** dans `sendApprovalRequestIfNeeded` : tant que
   `pairingStore.pairing(for: peer.id) == nil`, l'annonce est reportée et
   `restartPairingIfNeeded(for:)` relance le pairage si rien n'est en vol.
2. **Rejeu automatique** : `retryDeferredApprovalRequests()` est appelé à
   chaque point où le pairage ou la session devient utilisable
   (installation de clé de session, pairage abouti, reconnexion) —
   l'annonce repart toute seule, sans intervention.
3. **Observabilité** : `ConnectionManager.recordRejection` mémorise le
   dernier contrôle écarté dans `lastReceptionRejection`
   (`Network/ReceptionRejection.swift`) avec sa cause exacte —
   `peerNotPaired`, `keyMismatch`, `signatureInvalid`, `missingPublicKey`,
   `identityMismatch`, `replay`, `secureSessionNotReady` — et un
   `userFacingMessage` en français. **Aucune décision de sécurité n'est
   modifiée** : le rejet reste un rejet, il devient seulement lisible.

L'annonce reportée reste bornée : `armAnnouncementTimeout`
(**30 s**, `announcementGracePeriod`) évite qu'un `transferRequest`
différé laisse le transfert « Préparation » indéfiniment.

### Défaut D — le délai d'activité ne savait traiter que les envois

`restartTransferActivityTimeout` n'avait qu'un seul chemin de sortie,
`interruptOutgoingTransfer`, qui **retourne immédiatement** quand le
transfert n'est pas dans la file sortante :

```swift
private func interruptOutgoingTransfer(transferID: UUID) {
    guard outgoingTransferQueue.contains(transferID) else { return }   // ← réception : no-op
    ...
}
```

**Résultat** : côté réception, le délai armé à chaque morceau reçu n'avait
**aucun effet**. Un iPhone dont le Mac se taisait restait « En cours »
figé, sans interruption, sans reprise, sans erreur.

**Correctif** : le handler devient sensible à la direction —
`.outgoing` → `interruptOutgoingTransfer`, `.incoming` →
`interruptStalledIncomingTransfer` (fermeture du writer, conservation du
`.partial`, persistance de la métadonnée de reprise, passage à
`.interrupted`). Hors session, la coupure est toujours traitée comme
récupérable, jamais comme un échec.

### Défaut E — une réception interrompue ressuscitait en « En cours »

```swift
// Transfer/IncomingTransferManager.swift — AVANT
func interruptTransfer(transferID: UUID) {
    Task { [sink] in await sink.interrupt(transferID: transferID) }
    store.updateProgress(                       // ← force .transferring
        transferID: transferID,
        transferredBytes: partialFileBytes(transferID: transferID)
    )
}
```

`TransferStore.updateProgress` pose `.transferring` par contrat (c'est son
rôle pendant un flux de morceaux). Comme `AirBridgeCore` marquait
`.interrupted` **avant** d'appeler ce chemin — et comme
`interruptActiveTransfers` l'avait déjà fait à la fermeture de session —
l'appel suivant **ressuscitait** le transfert dans un état actif.

Conséquences en chaîne :

- la reprise automatique ne sélectionne que les états `.interrupted` →
  plus jamais repris ;
- `resumeIncoming` exige `store.isResumable` → la reprise manuelle
  échouait aussi ;
- l'UI affichait « En cours » à 0 % alors qu'aucun octet n'arrivait.

**Correctif** : `store.markInterrupted(transferID:transferredBytes:)`, qui
pose `.interrupted` sans toucher au caractère non terminal de l'état.

```swift
// APRÈS
store.markInterrupted(
    transferID: transferID,
    transferredBytes: partialFileBytes(transferID: transferID)
)
```

---

## 3. Récapitulatif des modifications

| Fichier | Modification | Effet utilisateur |
|---|---|---|
| `Core/AirBridgeCore.swift` | `OutgoingStartOutcome`, `armAcceptedStartTimeout` (20 s), `armAnnouncementTimeout` (30 s), barrière de pairage, `retryDeferredApprovalRequests()`, `restartPairingIfNeeded(for:)`, `recoverOrphanedApprovedTransfer`, `interruptStalledIncomingTransfer`, acceptation send-first + `markFailed` | Plus aucun « En attente » infini : ça démarre, ça échoue avec un motif, ou ça se reprend |
| `Network/ConnectionManager.swift` | `resolveControlConnection(preferred:)`, `lastReceptionRejection`, `recordRejection`, variantes de `sendTransferAccepted` / `sendTransferRejected` avec repli sur la session vivante | L'acceptation part même si la connexion d'origine a basculé ; un contrôle écarté devient lisible |
| `Network/ReceptionRejection.swift` *(nouveau)* | `Kind` (7 causes) + `userFacingMessage` | La cause exacte d'un « En attente » est nommée en français |
| `Discovery/BonjourService.swift` | `isAdvertisingReady`, `isBrowsingReady`, `isLocalNetworkAuthorizationDenied`, câblés sur les 10 handlers d'état | Le panneau sait si l'écoute/la recherche Bonjour sont réellement actives |
| `Transfer/IncomingTransferManager.swift` | `interruptTransfer` → `store.markInterrupted` | Une réception interrompue reste « Interrompu » et reprisable |
| `Features/Diagnostics/SharingDiagnostics.swift` *(nouveau)* | Constructeur **pur** : `DiagnosticsInput` → `[DiagnosticItem]` | 8 lignes de diagnostic testables sans réseau |
| `Features/Diagnostics/DiagnosticsCollector.swift` *(nouveau)* | `NetworkPathSnapshot`, `LocalNetworkPathMonitor`, collecte depuis le Core | État réel (chemin réseau, Bonjour, session, pairage, extensions) |
| `Features/Diagnostics/DiagnosticsView.swift` *(nouveau)* | Section SwiftUI « Diagnostic du partage » | Réponse visible dans l'app, plus besoin de `Console.app` |
| `UI/Settings/SettingsView.swift` (+ 3 points d'appel) | `var core: AirBridgeCore? = nil`, section insérée avant « Appareils appairés » | Accès : Réglages (⌘ , sur macOS, onglet Réglages sur iOS) |

---

## 4. Le panneau « Diagnostic du partage »

Réglages ▸ **Diagnostic du partage**. Les lignes suivent la chaîne réelle
d'un partage, de la carte réseau jusqu'au menu Partager : lire le panneau
de haut en bas revient à suivre le parcours du fichier. La **première
ligne en échec** est la cause.

| # | Ligne | Bloquant si | Action proposée |
|---|---|---|---|
| 1 | Connexion réseau | aucun chemin `.satisfied` | même Wi-Fi / Bluetooth, relancer AirBridge |
| 2 | Autorisation « Réseau local » | refus système | Réglages ▸ Confidentialité ▸ Réseau local |
| 3 | Découverte Bonjour (`_airbridge._tcp`) | publication **ou** recherche inactive | redémarrer AirBridge (publication) / relancer le radar, vérifier le routeur (recherche) |
| 4 | Session avec le destinataire | session sécurisée (ECDH) non établie | fermer/rouvrir la connexion depuis le radar |
| 5 | Pairage du destinataire | pair non enregistré **ou** bloqué | relancer la connexion (re-pairage auto) / débloquer |
| 6 | Dernier contrôle écarté | un rejet enregistré | cause exacte + action (cette ligne n'apparaît que s'il y a eu rejet) |
| 7 | Pare-feu / filtrage réseau | *jamais bloquant* | consignes de vérification (non mesurable depuis une app sandboxée) |
| 8 | Menu Partager | extension absente **ou** App Group indisponible | réinstaller depuis Xcode / vérifier les capacités |

États possibles : `.ok`, `.warning` (fonctionne mais à surveiller),
`.failure` (bloquant), `.unchecked` (non mesurable depuis l'application —
le panneau ne prétend alors jamais connaître la réponse). Un pied de
section résume : « *2 points bloquants détectés* ».

Le constructeur (`SharingDiagnosticsBuilder`) est une fonction pure : il ne
touche ni au réseau ni au Core, d'où sa couverture de tests complète.

---

## 5. Vérifications réseau, pare-feu, autorisations, partage

### 5.1 Ce qui est déjà correct dans le projet (vérifié)

| Élément | Emplacement | État |
|---|---|---|
| `NSBonjourServices = _airbridge._tcp` | `Info.plist` | ✅ présent |
| `NSLocalNetworkUsageDescription` | `Info.plist` | ✅ présent (sans lui, iOS n'affiche **jamais** la demande d'accès et la découverte échoue en silence) |
| `com.apple.security.network.client` | `AirBridge-macOS.entitlements` | ✅ |
| `com.apple.security.network.server` | `AirBridge-macOS.entitlements` | ✅ (indispensable pour **recevoir** sur macOS) |
| `com.apple.security.files.user-selected.read-write` | `AirBridge-macOS.entitlements` | ✅ |
| `com.apple.security.files.downloads.read-write` | `AirBridge-macOS.entitlements` | ✅ (dossier de réception par défaut) |
| App Group `group.com.airbridge.shared` | entitlements macOS **et** iOS + `FinderService.entitlements` / `ShareExtension.entitlements` | ✅ (canal de remise des fichiers du menu Partager) |
| `NSExtensionPointIdentifier = com.apple.share-services` | `MacOS/FinderService/Info.plist` **et** `ShareExtension/Info.plist` | ✅ (seul canal qui alimente le menu Partager du Finder sur macOS 26 ; l'ancien `NSServices` y est inerte) |
| Extensions embarquées | cibles `FinderService` (macOS) / `ShareExtension` (iOS) + phases « Embed » dans la cible `AirBridge` | ✅ |

Aucune correction de configuration n'était nécessaire : le blocage venait
du code, pas des plists ni des entitlements.

### 5.2 macOS — pare-feu et réseau local

1. **Réglages Système ▸ Réseau ▸ Pare-feu**
   - « Bloquer toutes les connexions entrantes » doit être **désactivé** —
     activé, il produit exactement le symptôme rapporté (le Mac ne peut
     plus écouter, donc ni recevoir ni être découvert) ;
   - **Options…** ▸ AirBridge doit être autorisé en **réception**
     (« Autoriser les connexions entrantes »).
2. **Réglages Système ▸ Confidentialité et sécurité ▸ Réseau local** ▸
   AirBridge activé (macOS Sequoia et suivants).
3. **VPN / filtres tiers** (Little Snitch, LuLu, Cisco Umbrella, Zscaler…) :
   un VPN actif reroute le trafic local et casse mDNS. Le diagnostic le
   signale indirectement (chemin réseau sans DNS, ou aucune interface
   locale).
4. **Port** : AirBridge n'ouvre pas de port fixe côté découverte — Bonjour
   utilise **mDNS, UDP 5353** (multicast). Le port TCP de transfert est
   choisi dynamiquement et annoncé par le service ; un pare-feu qui
   n'autorise qu'une liste de ports fixes le bloquera.
5. **Même réseau** : le Mac et l'iPhone doivent être sur le même Wi-Fi
   (ou à portée Bluetooth pour le pair-à-pair). Un partage de connexion
   les sort du même réseau local — signalé en `.warning` par la ligne
   « Connexion réseau ».

### 5.3 iOS — autorisation et réseau

1. **Réglages ▸ AirBridge ▸ Réseau local** : activé. Si le bouton
   n'apparaît pas, l'autorisation n'a jamais été demandée → supprimer et
   réinstaller l'app (elle sera redemandée au premier lancement).
2. **Wi-Fi** actif et identique au Mac ; éviter les **réseaux invités**.
3. Ne pas tuer AirBridge en arrière-plan pendant un transfert : iOS
   suspend l'app, la session tombe, le transfert passe en `.interrupted`
   (désormais réellement repris, grâce au défaut E corrigé).

### 5.4 Routeur / borne Wi-Fi

- **AP isolation / « isolation des clients »** : à **désactiver** — activée,
  les appareils du même Wi-Fi ne se voient pas (radar vide des deux côtés).
- **mDNS / Bonjour / UDP 5353** : autorisés (certains routeurs grand
  public filtrent le multicast ; certains répéteurs ne le relayent pas —
  brancher les deux appareils sur la même borne aide à le vérifier).
- **IGMP snooping** mal configuré : même effet.
- Wi-Fi **6E/7 GHz** seul : certains clients n'y font pas de multicast
  fiable — tester en 2,4/5 GHz.

### 5.5 Réinitialisation ciblée (dans l'ordre)

1. Réglages ▸ **Diagnostic du partage** → corriger la première ligne en
   échec.
2. Si la ligne « Pairage » est en cause : Réglages ▸ **Appareils appairés**
   ▸ oublier l'appareil, puis se reconnecter depuis le radar (le pairage
   TOFU se refait, la clé P-256 est régénérée dans le Keychain).
3. Annuler le transfert bloqué puis le relancer : le diagnostic est
   réévalué à chaque affichage.

---

## 6. Accéder à AirBridge depuis le menu « Partager »

### 6.1 macOS (Finder)

1. Sélectionner le(s) fichier(s) dans le **Finder**.
2. Cliquer sur le bouton **Partager** de la barre d'outils (ou **clic
   droit ▸ Partager**).
3. Choisir **AirBridge**.

**Si l'entrée n'apparaît pas** :

- Réglages Système ▸ **Général ▸ Connexion et extensions ▸ Extensions**,
  puis la catégorie de partage : cocher **AirBridge**, et relancer le
  Finder (`⌥` + clic droit sur le Finder dans le Dock ▸ Relancer, ou
  `killall Finder`).
- Vérifier que `FinderService.appex` est bien dans
  `AirBridge.app/Contents/PlugIns/` — c'est la ligne « Menu Partager » du
  diagnostic qui le dit. S'il manque : réinstaller depuis Xcode
  (**Produit ▸ Exécuter**), l'extension est copiée à la construction.
- Le menu Partager du Finder n'est alimenté **que** par les extensions
  `com.apple.share-services` : c'est bien le point d'extension déclaré ici.

### 6.2 iOS (Fichiers, Photos, Aperçus…)

1. Ouvrir le document ou la photo, puis **Partager** (icône
   « carré avec flèche vers le haut »).
2. Choisir **AirBridge** dans la rangée d'extensions.

**Si l'entrée n'apparaît pas** : Partager ▸ **Plus (…)** ▸ **Modifier** ▸
activer **AirBridge** et le placer en favori.

Limites d'activation (déclarées dans `ShareExtension/Info.plist`) :
jusqu'à **20 fichiers**, **20 images**, **5 vidéos**, **1 URL** ; le texte
seul n'est pas accepté.

### 6.3 Ce qui se passe ensuite (chaîne de remise)

```
Extension (processus séparé)
   │  1. copie les fichiers + manifeste atomique
   ▼
App Group  group.com.airbridge.shared/PendingShares/<batch>/
   │  2. notification Darwin  com.airbridge.share.pending   (filet de sécurité)
   │  3. ouverture de l'app   airbridge://receive?batch=<batchID>   (canal principal)
   ▼
Application (PendingShareObserver → PendingShareController.present)
   │  4. feuille d'envoi pré-remplie — AUCUN envoi automatique
   ▼
Sélection du destinataire → transferRequest → transferAccepted → chunks
```

Trois chemins de remise coexistent (URL scheme, Darwin, balayage de
l'App Group au lancement) avec **déduplication par signature** du lot :
un même partage ne peut jamais être présenté — donc envoyé — deux fois.

**Point important** : il n'existe **aucune API publique** permettant à une
extension de lancer directement l'application hôte. L'extension *demande*
l'ouverture via `extensionContext.open(_:)` / le schéma `airbridge://` ;
si l'app n'est pas lancée, le lot reste stationné dans l'App Group et est
récupéré au prochain démarrage (balayage). Les fichiers ne sont supprimés
qu'après livraison effective (`pruneDeliveredBatches`), jamais à la
fermeture de la feuille.

### 6.4 Autre porte d'entrée : « Ouvrir avec »

`Info.plist` déclare aussi AirBridge comme destinataire de documents
(`CFBundleDocumentTypes`, rôle **Viewer**, rang **Alternate**,
`public.item`, avec `LSSupportsOpeningDocumentsInPlace`) :
**Finder ▸ Ouvrir avec ▸ AirBridge** (macOS) et **Fichiers ▸ Partager ▸
Ouvrir dans AirBridge** (iOS) aboutissent sur la même feuille d'envoi. Le
rang *Alternate* est volontaire : AirBridge n'usurpe jamais l'application
par défaut d'un type de document.

---

## 7. Tests

### 7.1 Ajoutés

| Fichier | Couverture |
|---|---|
| `Tests/AirBridgeTests/SharingDiagnosticsTests.swift` | Constructeur pur : état nominal sans ligne bloquante, ordre des lignes conforme à la chaîne de partage, chaque cause de blocage → une ligne `.failure` **avec** action correctrice, pare-feu jamais prétendu connu, consignes du menu Partager spécifiques par plateforme, `ReceptionRejection.userFacingMessage` pour les 7 causes |
| `Tests/AirBridgeTests/IncomingInterruptionStateTests.swift` | Régression défaut E : interruption de réception → `.interrupted` (jamais `.transferring`), non-résurrection après fermeture de session, idempotence, `.interrupted` non terminal et toujours dans la liste active, contraste avec l'annulation qui reste terminale |
| `Tests/AirBridgeTests/TransferTimeoutReplacementTests.swift` | Réarmement : `start` remplace le délai précédent du même transfert (fondement de l'enchaînement 300 s → 30 s → 20 s → 30 s), expiration unique, `cancel`/`cancelAll`, indépendance entre transferts (cas d'un lot) |

### 7.2 Remis en conformité

Sept attentes de tests décrivaient un comportement **antérieur au
durcissement déjà présent dans le code** (la politique
d'authentification n'a pas été modifiée ici) :

- `AuthenticationPolicyTests` : v1 → `.required` (plus aucun mode
  permissif), pair bloqué → `.forbidden`, `transferRequest` autorisé pour
  un pair inconnu mais `transferAccepted` non (nouveau test dédié).
- `SecureReceptionPipelineTests` : politique stricte en v1 ;
  `.optionalLegacy` **n'accepte plus** un message non signé.
- `MessageAuthenticatorTests` : un contrôle non signé est rejeté même en
  `.optionalLegacy`.
- `SecureHandshakePhase2Tests` : `testV1V2CrossProtocolCompatibility`
  remplacé par `testV1IsRefusedWithoutDowngrade` — la v1 est refusée à
  trois niveaux (`ProtocolCompatibility.isSupported(1) == false`,
  politique `.required`, vérification de signature). Conserver un repli v1
  aurait permis à un attaquant de faire accepter des mutations non
  authentifiées en annonçant simplement une version ancienne.

### 7.3 Exécution

⚠️ **Aucune toolchain Swift n'est disponible dans l'environnement où ces
modifications ont été écrites** : elles ont été vérifiées par inspection
(API appelées, signatures, isolation d'acteurs, équilibrage syntaxique),
**pas compilées**. À exécuter sur un Mac :

```bash
xcodebuild test \
  -project AirBridge.xcodeproj \
  -scheme AirBridge \
  -destination 'platform=macOS'

xcodebuild test \
  -project AirBridge.xcodeproj \
  -scheme AirBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Les nouveaux fichiers sont automatiquement inclus dans les cibles : le
projet utilise des `PBXFileSystemSynchronizedRootGroup` (`Features/` pour
l'app, `Tests/` pour `AirBridgeTests`).

Rappel de configuration ayant guidé l'écriture :
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (d'où les `nonisolated`
explicites sur les types purs `DiagnosticsInput`, `DiagnosticItem`,
`NetworkPathSnapshot`, `ReceptionRejection`, `OutgoingStartOutcome`),
`SWIFT_VERSION = 5.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`,
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`.

---

## 8. Invariants de sécurité préservés

- Aucune vérification de signature supprimée ou assouplie ; le pipeline de
  réception reste `verify → observe` (un message invalide n'empoisonne
  jamais le store anti-rejeu).
- La barrière de pairage **retarde** l'annonce au lieu de contourner
  l'authentification : elle renforce la politique, ne l'affaiblit pas.
- `lastReceptionRejection` est purement diagnostique : il n'influe sur
  aucune décision.
- Identité P-256 en Keychain, ECDH éphémère, ChaCha20-Poly1305 par
  morceau, anti-rejeu, pairage TOFU et `trustState` : inchangés.
- Les délais ajoutés (20 s / 30 s) bornent l'attente sans jamais
  court-circuiter une garde : à expiration, le transfert **échoue avec un
  motif et le pair est prévenu**.
