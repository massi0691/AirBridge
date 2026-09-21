# Revue de code — Nouvelle UI macOS : découverte de l'iPhone, connexion et accès aux Réglages

Branche : `arena/01a0c4e9-airbridge` (base `f5632e9`, PR #7 « nouvelle UI »)
Périmètre : `AirBridge/AirBridgeApp.swift`, `UI/MacTransferWorkspaceView.swift`, `UI/MainView.swift`, `Discovery/BonjourService.swift`, `Network/ConnectionManager.swift`, `Features/Discovery/*`, `Features/Sharing/*`, `UI/Settings/SettingsView.swift`.

> Méthode : revue **statique** (lecture de code, chaînes d'appels, `grep`).
> Aucun outil Apple (`xcodebuild`, `swiftc`) n'est disponible dans cet
> environnement : les correctifs proposés sont relus ligne à ligne mais
> **doivent être compilés sur le Mac** (commandes au §5).

---

## 0. Résumé exécutif

Les deux symptômes signalés sont **deux régressions d'interface introduites
par la nouvelle UI macOS** — pas des pannes réseau :

| Symptôme | Cause racine | Preuve |
|---|---|---|
| Impossible de découvrir / lier l'iPhone depuis le Mac | La nouvelle racine macOS (`MacTransferWorkspaceView`) n'expose **aucune surface de découverte** : le radar n'existe que dans `MainView`, qui n'est plus montée sur macOS | `AirBridgeApp.swift:271-286` ; `UI/MacTransferWorkspaceView.swift:28-34` et `:237-244` (avant patch) |
| Aucun accès aux informations de réglages | Aucune route vers `SettingsView` (fichier de réception, notifications, appareils appairés) et aucune scène `Settings` (donc pas non plus de ⌘ ,) | `UI/MacTransferWorkspaceView.swift:149-171` (avant patch) ; `SettingsView` appelée uniquement depuis `UI/MainView.swift:217` |
| (probable, à confirmer) radar toujours vide | Autorisation **« Réseau local »** refusée depuis macOS 15 : le `NWBrowser` n'émet plus aucun résultat et l'app n'en disait rien | `Discovery/BonjourService.swift:193-215` + `:136-146` (avant patch, seulement des logs) |

Le correctif est **appliqué** en deux patchs (§4) :

* **Patch A — `UI/MacTransferWorkspaceView.swift`** : la sidebar macOS reçoit
  deux sections, **« Appareils »** (radar de découverte/connexion/appairage)
  et **« Réglages »** (`SettingsView`), en plus des trois filtres de
  transfert. L'ouverture se fait sur « Appareils ».
* **Patch B — `Discovery/BonjourService.swift`** : la couche Bonjour publie un
  état d'incident observable (`localNetworkIssue`), affiché en bandeau dans
  la section « Appareils » avec deux actions : « Ouvrir Réglages Système » et
  « Relancer la recherche ».

---

## 1. Symptôme 1 — « je n'arrive pas à découvrir l'iPhone »

### 1.1 Ce qui fonctionne réellement (le réseau n'est pas en cause)

1. `AirBridgeApp.CoreHolder.init` appelle `core.start()`
   (`AirBridge/AirBridgeApp.swift:161`).
2. `AirBridgeCore.start()` fait bien les deux gestes, **sur macOS comme sur
   iOS** :

   ```swift
   func start() {                       // Core/AirBridgeCore.swift:3324-3327
       bonjourService.startAdvertising()
       bonjourService.startDiscovery()
   }
   ```

3. `BonjourService.startDiscovery()` crée un `NWBrowser` sur
   `_airbridge._tcp` (`Discovery/BonjourService.swift:244-261`) et alimente
   `discoveredDevices` à chaque changement de résultats
   (`:317-370`).

Autrement dit : **le Mac découvre bien l'iPhone**, la liste
`bonjourService.discoveredDevices` se remplit. Ce qui manque, c'est
l'affichage.

### 1.2 Le point de rupture

Les seules vues qui lisent `discoveredDevices` sont :

* `RadarFullScreenView` (le radar, avec l'appel `viewModel.connect(to:)`) ;
* `DiscoveryView` — **compilée uniquement sur iOS** (`#if os(iOS)`,
  `Features/Discovery/DiscoveryView.swift:31` et `:304`).

Or depuis le passage à la nouvelle UI, la racine macOS n'est plus `MainView`
(qui contenait `case .devices: RadarFullScreenView(core: core)`,
`UI/MainView.swift:204-206`) mais `MacTransferWorkspaceView` :

```swift
#if os(macOS)
        MacTransferWorkspaceView(core: holder.core,     // AirBridgeApp.swift:277
                                 pendingShareController: pendingShareController)
#else
        MainView(...)                                   // AirBridgeApp.swift:282 — iOS uniquement
#endif
```

`MacTransferWorkspaceView` ne connaît que trois filtres de transfert
(`active`, `all`, `history`, l.28-34 avant patch) et sa colonne de détail est
réduite à *zone de dépôt + tableau* (l.237-244). **Aucun élément d'interface
ne présente les appareils découverts ni ne propose de se connecter.**
`ConnectionManager.connect(to:)` (`Network/ConnectionManager.swift:630`) —
seule API capable d'ouvrir une session côté client — n'a donc plus aucun
appelant sur macOS.

### 1.3 Pourquoi il n'existe aucun chemin de secours

Toutes les autres surfaces exigent une session **déjà** ouverte :

| Surface macOS | Blocage |
|---|---|
| Zone de dépôt / « Choisir des fichiers… » | `.disabled(!isConnected)` (`MacTransferWorkspaceView.swift:272`) ; `handleDrop` refuse sans pair (l.556-573) ; `handleImporterCompletion` exige `isConnected` (l.575-581) |
| `ShareView` (partage, extension Finder) | bouton Envoyer `.disabled(!viewModel.canShare)` (`Features/Sharing/ShareView.swift:273`) avec `canShare = isConnected && !attachedURLs.isEmpty` (`ShareViewModel.swift:103`) ; `send(to:)` rejette tout destinataire ≠ appareil connecté (`ShareViewModel.swift:181-198`) |
| `RecipientSelector` | explicitement **présentationnel** : « It never opens a connection or talks to the Core directly » (`RecipientSelector.swift:17-20`) |
| Aide affichée dans la sidebar | « Utilisez le radar depuis votre iPhone pour lier un appareil. » (l.219 avant patch) → renvoie l'utilisateur vers l'iPhone |

Conséquence : côté Mac, une session ne peut naître **que** d'une connexion
*entrante* initiée par l'iPhone (`Core/AirBridgeCore.swift:1553-1556` →
`ConnectionManager.accept(_:)`, `Network/ConnectionManager.swift:850`).

* Mac → iPhone : impossible (aucune UI d'initiation).
* Mac ↔ Mac : impossible pour la même raison.
* iPhone → Mac : possible, **mais fragile** : l'annonce Bonjour de l'iPhone ne
  survit pas à la mise en arrière-plan (aucun `UIBackgroundModes` dans
  `Info.plist` ; le `NWListener` est coupé à la suspension), donc « utilisez
  le radar depuis l'iPhone » n'est pas une réponse acceptable — surtout pour
  envoyer un fichier **vers** l'iPhone.

---

## 2. Symptôme 2 — « je n'ai pas accès aux informations de réglages »

* `MacTransferFilter` ne contient que des filtres de transfert — aucune
  entrée « Réglages ».
* `SettingsView` (dossier de réception, notifications, **appareils appairés
  avec confiance / blocage / oubli**) n'est référencée que par `MainView`
  (`UI/MainView.swift:217-222`), morte sur macOS.
* `AirBridgeApp.body` ne déclare qu'une scène `WindowGroup`
  (`AirBridgeApp.swift:201-216`) : **aucune scène `Settings`**, donc ni ⌘ ,
  ni « AirBridge ▸ Réglages… ».

Conséquences concrètes sur le Mac : impossible de vérifier l'empreinte d'un
pair, de le marquer « de confiance », de le bloquer ou de l'oublier, de
changer le dossier de réception, ni de contrôler l'état des
notifications/autorisations.

---

## 3. Cause aggravante à vérifier au runtime — autorisation « Réseau local »

Depuis macOS 15 (et iOS 14), Bonjour est soumis à la *local network privacy* :
l'app doit déclarer `NSBonjourServices` **et** `NSLocalNetworkUsageDescription`,
et l'utilisateur doit autoriser l'accès. En cas de refus, le `NWBrowser`
n'émet plus aucun résultat et remonte une erreur d'autorisation
(`NoAuth -65555`, parfois `PolicyDenied -72008`) — sans qu'aucune UI ne
l'expose [1](https://developer.apple.com/forums/thread/735862)
[2](https://developer.apple.com/forums/tags/bonjour).

**Bonne nouvelle : le projet est déjà correctement configuré.**

* `Info.plist:53-64` → `NSBonjourServices = [_airbridge._tcp]` +
  `NSLocalNetworkUsageDescription`.
* `AirBridge-macOS.entitlements` → `app-sandbox`, `network.client`,
  `network.server` (nécessaires pour écouter et sortir dans le sandbox macOS).

**Le trou, en revanche :** cette erreur n'existait que dans les logs
(`BonjourService.swift:136-146` et `:200-213` avant patch) : l'utilisateur
voyait un radar vide, **sans cause ni action possible**. C'est exactement le
symptôme « j'arrive pas à découvrir ».

À vérifier sur la machine :

1. Réglages Système ▸ Confidentialité et sécurité ▸ **Réseau local** →
   *AirBridge* doit être **activé** (l'app doit être relancée après octroi).
2. Il n'existe **aucun moyen officiel** de remettre cette autorisation à
   l'état « non déterminé » sur macOS (FB14944392) : basculer l'interrupteur
   OFF puis ON, relancer l'app, ou réinstaller [4](https://forums.macrumors.com/threads/local-network-access-nightmare.2448144/).
3. *Entitlement multicast* (`com.apple.developer.networking.multicast`) :
   **inutile ici**. Il concerne le multicast/broadcast direct et la navigation
   sur des types Bonjour **non déclarés** ; nos types sont déclarés dans
   `NSBonjourServices` [3](https://apple.stackexchange.com/questions/477693)
   [5](https://developer.apple.com/forums/thread/655920).
4. Peer-to-peer : `includePeerToPeer = true` est déjà posé des deux côtés
   (`BonjourService.makeParameters()`), ce qui est la condition pour que deux
   appareils se trouvent via AWDL même hors du même SSID
   [6](https://developer.apple.com/forums/thread/808917).

---

## 4. Correctif appliqué

### 4.1 Patch A — `UI/MacTransferWorkspaceView.swift` (1 seul fichier, zéro nouvelle route réseau)

1. **Sidebar** : `MacTransferFilter` gagne `.devices` (« Appareils »,
   `antenna.radiowaves.left.and.right`) et `.settings` (« Réglages »,
   `gearshape`) ; l'ouverture par défaut se fait sur `.devices`
   (comme l'onglet par défaut de l'UI iPhone) ; le badge « Appareils »
   affiche le nombre d'appareils découverts.
2. **Détail routé** :

   ```swift
   @ViewBuilder
   private var workspaceDetail: some View {
       switch effectiveFilter {
       case .devices:            devicesDetail      // RadarFullScreenView
       case .active, .all, .history: transfersDetail // dépôt + tableau
       case .settings:           settingsDetail     // SettingsView
       }
   }
   ```

3. `.devices` → **réutilisation du radar existant** `RadarFullScreenView` :
   tap sur une bulle → `connect(to:)`, attente de session,
   `PairingConfirmationView` automatique si le pair n'est pas de confiance,
   boutons « Envoyer des fichiers » / « Déconnecter ». C'est la surface déjà
   utilisée par l'iPhone **et déjà compilée pour macOS** (elle était branchée
   sur la branche macOS de `MainView`) : aucun chemin réseau nouveau, aucune
   divergence entre plateformes.
4. `.settings` → `SettingsView(receivedFolderStore:notificationManager:pairingStore:)`
   avec les dépendances du Core (mêmes arguments que `MainView.swift:217-222`).
5. Message d'aide corrigé (« Ouvrez “Appareils” pour rechercher un appareil
   sur le même réseau. ») + bouton **« Rechercher un appareil »** qui bascule
   la sidebar sur `.devices`.

### 4.2 Patch B — `Discovery/BonjourService.swift` (état observable)

* `advertisingIssue` (listener) et `browsingIssue` (browser) + propriété
  observable `var localNetworkIssue: String?` (la recherche est prioritaire) ;
* renseignés dans les `stateUpdateHandler` : `.failed` toujours,
  `.waiting` **seulement** pour une erreur d'autorisation
  (`isAuthorizationError` : -65555 / -72008) afin de ne pas faire clignoter
  le bandeau à chaque reconfiguration réseau ; purgés sur `.ready`/`.cancelled` ;
* helper `localNetworkHint(stage:error:)` qui produit un message actionnable
  (une seule source de texte, réutilisable par iOS plus tard).

### 4.3 Bandeau dans la section « Appareils »

Si `core.bonjourService.localNetworkIssue != nil`, un bandeau
« Recherche d'appareils limitée » s'affiche **au-dessus** du radar, avec le
message, **« Ouvrir Réglages Système »** (deep-link
`x-apple.systempreferences:…Privacy_LocalNetwork`, repli sur la racine
Confidentialité) et **« Relancer la recherche »**
(`stopDiscovery()` + `startDiscovery()` : un `NWBrowser` en échec ne se
relance pas tout seul, et un nouvel octroi d'autorisation exige un nouveau
navigateur).

### 4.4 Portée et sûreté

* Patch A : entièrement sous `#if os(macOS)` (fichier déjà gardé) → **iOS
  inchangé**.
* Patch B : ajoute un état, ne retire ni ne modifie aucune API existante
  → iOS inchangé (le bandeau n'y est pas affiché ; à brancher plus tard si
  souhaité, le cas « radar vide » est le même sur iPhone).
* Le seul changement de comportement visible : **l'app macOS s'ouvre
  maintenant sur « Appareils »** au lieu de « En cours ». Retour arrière en
  une ligne (`@State private var filter: MacTransferFilter? = .devices`
  → `.active`).

Diff :

```bash
git diff            # 2 fichiers : UI/MacTransferWorkspaceView.swift, Discovery/BonjourService.swift
git diff --stat
```

Repères dans le code patché (nouvelle numérotation) :

| Fichier | Élément | Ligne |
|---|---|---|
| `UI/MacTransferWorkspaceView.swift` | `enum MacTransferFilter` (+ `.devices`, `.settings`) | 36 |
| | ouverture par défaut sur `.devices` | 126 |
| | bouton « Rechercher un appareil » | 252 |
| | routage du détail (`workspaceDetail`) | 276 |
| | détail « Appareils » (`devicesDetail`) | 299 |
| | détail « Réglages » (`settingsDetail`) | 322 |
| | bandeau d'incident + actions | 334 |
| | `restartDiscovery()` / `openLocalNetworkSettings()` | 374 / 382 |
| `Discovery/BonjourService.swift` | états `advertisingIssue` / `browsingIssue` | 38 / 41 |
| | `var localNetworkIssue` (observable) | 55 |
| | `isAuthorizationError` / `localNetworkHint` | 99 / 110 |

---

## 5. Vérification (à exécuter sur le Mac)

⚠️ **Ces correctifs n'ont pas pu être compilés ici** (pas de toolchain
Apple en sandbox). Compilation et tests :

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -configuration Debug -destination 'platform=macOS' \
  build 2>&1 | tee /tmp/airbridge-build.log | tail -40
grep -c "error:" /tmp/airbridge-build.log        # attendu : 0

xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=macOS' test 2>&1 | tail -40
```

### Checklist fonctionnelle macOS

- [ ] Au lancement, la fenêtre s'ouvre sur **Appareils** (radar visible).
- [ ] AirBridge ouvert au premier plan sur l'iPhone (même Wi-Fi) : l'iPhone
      apparaît sur le radar en ~1-2 s ; badge « Appareils » = 1.
- [ ] Clic sur la bulle → « Connexion en cours… » → « Connecté à … » ; si le
      pair n'est pas de confiance, la feuille **Appairage** s'ouvre →
      « Faire confiance ».
- [ ] Section « En cours » : déposer un fichier (ou « Choisir des fichiers… »)
      → transfert vers l'iPhone (avant patch : bouton grisé, dépôt refusé).
- [ ] Sidebar ▸ **Réglages** : dossier de réception, notifications état,
      appareils appairés (empreinte, De confiance / Bloquer / Oublier).
- [ ] Réglages Système ▸ Confidentialité et sécurité ▸ Réseau local :
      désactiver AirBridge, relancer → **bandeau orange** ; « Relancer la
      recherche » après réactivation ré-affiche l'iPhone.

### Non-régression

- [ ] Build iOS : les vues macOS ne sont pas compilées ; `localNetworkIssue`
      n'ajoute qu'un état.
- [ ] Suite XCTest : `grep` confirme qu'aucun test ne référence
      `MacTransferFilter` ; `ShareViewModelTests` instancie `BonjourService`,
      mais le patch ne touche ni son init ni `discoveredDevices`.

---

## 6. Autres constats de la revue (hors périmètre du symptôme)

1. **Notifications : boutons « Accepter » / « Refuser » inopérants.**
   Il existe **deux** `NotificationManager` : celui de l'app
   (`AirBridgeApp.swift:91`, utilisé pour `.environment` et pour câbler
   `onAcceptTransfer`/`onRejectTransfer` en `:154-157`) et celui du Core
   (`AirBridgeCore.swift:30`, seul à émettre les notifications : `:1951`,
   `:2866`, `:3080`…). Or `NotificationManager.init()` fait
   `UNUserNotificationCenter.current().delegate = notificationDelegate`
   (`Notifications/NotificationManager.swift:148-150`) : la **dernière**
   instance créée (celle du Core, créée au `onAppear` de la fenêtre, donc
   après `AirBridgeApp.init`) devient le delegate… et ses closures
   `onAcceptTransfer`/`onRejectTransfer` ne sont jamais assignées → les
   actions de notification ne font rien.
   *Correctif conseillé* : une seule instance partagée (l'injecter dans
   `AirBridgeCore` **et** dans l'environnement), ou câbler les callbacks sur
   `core.notificationManager`.
2. **Pattern de navigation** : `NavigationLink(value:)` dans la sidebar sans
   `.navigationDestination(for:)` (hérité de `MainView`). Cela fonctionne par
   tag implicite, mais la forme canonique macOS est `List(selection:)` +
   lignes simples ; à nettoyer quand la sidebar sera groupée en sections.
3. **`RadarFullScreenView` reste une vue iPhone** : fond noir plein écran,
   `.preferredColorScheme(.dark)`, pied de page à `safeAreaInset`. Elle
   fonctionne dans la colonne de détail (c'est le comportement d'avant la
   régression) mais une surface Mac-native serait plus juste : liste des
   appareils avec symbole, nom, modèle, état (disponible / de confiance /
   connecté), bouton « Connecter » / « Déconnecter », et état de recherche.
   À prévoir comme évolution UX, sans urgence.
4. **Pas de scène `Settings`** : ajouter pour `⌘ ,` et le menu
   « AirBridge ▸ Réglages… » :

   ```swift
   #if os(macOS)
   private var settingsScene: some Scene {
       Settings {
           if let coreHolder {
               SettingsView(
                   receivedFolderStore: coreHolder.core.receivedFolderStore,
                   notificationManager: coreHolder.core.notificationManager,
                   pairingStore: coreHolder.core.pairingStore
               )
           }
       }
   }
   #endif
   // puis dans `var body: some Scene { workspaceScene; #if os(macOS) settingsScene #endif }`
   ```

5. **Fichier mort** : `Discovery/DiscoveryManager.swift` ne contient qu'un
   `import Foundation` ; `DiscoveryView.swift` (legacy, iOS) reste un doublon
   du radar.
6. Le message « Utilisez le radar depuis votre iPhone… » était le seul indice
   fourni à l'utilisateur macOS : à proscrire comme mécanisme d'appairage
   (voir §1.3, dépendance à l'état de premier plan de l'iPhone).

---

## 7. Sources

- [1] Apple Developer Forums — *Getting Started with Bonjour* : `NSBonjourServices` + `NSLocalNetworkUsageDescription` obligatoires ; échec `NoAuth (-65555)` quand l'autorisation manque — https://developer.apple.com/forums/thread/735862
- [2] Apple Developer Forums — tag *Bonjour* (journaux `browser did change state, new: failed(-65555: NoAuth)`, absence d'API publique pour connaître l'état d'autorisation) — https://developer.apple.com/forums/tags/bonjour
- [3] Ask Different — portée de l'entitlement `com.apple.developer.networking.multicast` (multicast/broadcast + types Bonjour arbitraires) — https://apple.stackexchange.com/questions/477693
- [4] Forums MacRumors — *Local Network Access Nightmare* (impossibilité de réinitialiser l'autorisation Réseau local sur macOS, FB14944392) — https://forums.macrumors.com/threads/local-network-access-nightmare.2448144/
- [5] Apple Developer Forums — *When do we need the new `com.apple.developer.networking.multicast` entitlement?* — https://developer.apple.com/forums/thread/655920
- [6] Apple Developer Forums — *iOS 26 Network Framework AWDL* (`includePeerToPeer` à activer côté listener **et** browser) — https://developer.apple.com/forums/thread/808917
