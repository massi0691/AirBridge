# Correctifs du journal de lancement iOS (iPhone, iOS 27)

Lecture du journal collé dans le ticket, ligne par ligne : ce qui est un vrai
bug applicatif (corrigé ici), ce qui est du bruit système, et ce qui dépend du
provisionnement.

---

## 1. `nw_browser_fail_on_dns_error_locked … PolicyDenied(-65570)` + `advertising denied by policy`

**Cause : refus d'accès au réseau local (iOS 14+).** Ni la découverte
(`NWBrowser`) ni la publication (`NWListener`) ne fonctionnent : le radar reste
vide et personne ne peut nous joindre.

Deux bugs côté application, tous deux corrigés :

1. **Le code d'erreur n'était pas reconnu.** `BonjourService.isAuthorizationError`
   ne connaissait que `-65555` et `-72008` — jamais `-65570`
   (`kDNSServiceErr_PolicyDenied`), celui qu'iOS remonte réellement. Le refus
   passait donc totalement inaperçu : aucun bandeau, et le panneau de
   diagnostic affichait « aucun refus d'autorisation signalé ».
2. **Aucune récupération après autorisation accordée.** iOS laisse le
   navigateur `.waiting(-65570)` indéfiniment : même après avoir activé
   l'interrupteur dans Réglages, l'app restait muette jusqu'à son redémarrage.

Correctifs :

| Fichier | Changement |
| --- | --- |
| `Discovery/BonjourService.swift` | `-65570` ajouté à la détection (`isAuthorizationDenied(dnsCode:)`), codes exposés pour les tests |
| `Discovery/BonjourService.swift` | le refus détecté sur une moitié de la pile est propagé à l'autre (`registerLocalNetworkDenial`) : sur iOS, `NWListener` dit `.ready` alors que la publication est refusée |
| `Discovery/BonjourService.swift` | `handleApplicationDidBecomeActive()` : relance la pile au retour au premier plan si elle est dégradée (throttle 10 s) |
| `AirBridge/AirBridgeApp.swift` + `Core/AirBridgeCore.swift` | appel sur `scenePhase == .active` (`refreshDiscoveryIfNeeded()`) |
| `Features/Discovery/LocalNetworkIssueBanner.swift` (nouveau) | bandeau « Accès au réseau local requis » avec **Ouvrir les Réglages** (`UIApplication.openSettingsURLString` sur iOS, `x-apple.systempreferences:` sur macOS) et **Relancer la recherche** |
| `Features/Discovery/RadarFullScreenView.swift` | bandeau + statut « Accès au réseau local refusé » + état vide du radar adapté (pulsation figée, icône barrée) |
| `Features/Diagnostics/SharingDiagnostics.swift` | consigne iOS mise à jour (Réglages → AirBridge → Réseau local) et mention de l'« Adresse Wi-Fi privée » / Relais privé iCloud, qui produisent le même `PolicyDenied` même quand l'app est autorisée |

À faire côté machine (rien de code) : activer **Réglages → AirBridge → Réseau
local**. Si l'interrupteur n'apparaît pas, désinstaller puis réinstaller
l'application (iOS ne le crée qu'après une première demande).

---

## 2. `container_create_or_lookup_app_group_path_by_app_group_identifier: client is not entitled` + `Purge impossible : conteneur App Group indisponible`

**Cause : capacité *App Groups* non provisionnée.** Le profil de
provisionnement ne porte pas `group.com.airbridge.shared` (compte développeur
gratuit — qui n'y a pas droit — ou App Group non activé sur l'App ID).
Aucun code ne peut forcer cet accès : c'est une étape de provisionnement.

Ce qui était anormal, et corrigé :

* le conteneur était résolu **deux fois par balayage**, et le balayage tourne à
  chaque retour au premier plan → le journal système se remplissait de lignes
  identiques, au point de masquer les vrais incidents ;
* l'absence de conteneur était journalisée en `error` à chaque passage, alors
  qu'elle n'est pas une erreur de nettoyage : l'extension ne peut pas écrire
  de lot, donc il n'y a rien à purger.

Correctifs :

| Fichier | Changement |
| --- | --- |
| `MacOS/AirBridgeSharedState.swift` | `AirBridgeAppGroup.containerURL()` mémorise la résolution système (une seule ligne de journal par exécution) ; `resetContainerURLCache()` pour les tests |
| `AirBridge/AirBridgeApp.swift` | `sweepPendingShares()` sort immédiatement sans conteneur ; `presentNewestUnpresentedBatch()` passe par `AirBridgeAppGroup` |
| `Features/Sharing/PendingShareController.swift` | message unique en `notice` au lieu d'une `error` à chaque balayage |
| `Features/Diagnostics/DiagnosticsCollector.swift` | même résolution mémorisée pour le panneau de diagnostic |
| `Features/Diagnostics/SharingDiagnostics.swift` | la ligne « Menu Partager » explique l'origine (profil sans capacité App Groups, compte gratuit) et rappelle que les transferts AirBridge ⇄ AirBridge restent possibles |

Pour réactiver le partage depuis le menu système : activer **App Groups** sur
l'App ID puis dans *Signing & Capabilities* des cibles AirBridge, ShareExtension
(FinderService sur macOS), et réinstaller — compte payant requis.

---

## 3. Bruit système — **non corrigeable depuis l'application**

Ces lignes viennent d'iOS lui-même (présentes dans les journaux d'applications
sans rapport, y compris sur iOS 27) :

* `cannot add handler to 0 from 0 - dropping` (×4) ;
* `non-launching port is incompatible with service identifier
  "com.apple.PointerUI.pointeruid.default-service"`.

Elles n'ont aucun effet sur le fonctionnement d'AirBridge : les filtrer dans
Console.app (ou les ignorer) suffit.

Lignes purement informatives (aucune erreur) : `Permission notifications
accordée`, `Appareil local…`, `PairingStore créé`, `Listener Bonjour créé`,
`Service Bonjour publié`, `Le service Bonjour est prêt sur le port …`,
`La recherche Bonjour est prête`.

---

## Tests ajoutés

* `Tests/AirBridgeTests/BonjourLocalNetworkPolicyTests.swift` — verrouille la
  liste des codes refus (`-65570`, `-65555`, `-72008`) et l'absence de faux
  positifs sur les erreurs réseau (`-65540`, `-65537`, `ECONNREFUSED`…).
* `Tests/AirBridgeTests/PendingShareControllerTests.swift` —
  `test_prune_withoutAppGroupContainerIsASilentNoOp` : sans conteneur App
  Group, la purge est un sans-faute silencieux (aucune erreur remontée).

> Non exécutés ici : l'environnement de la session ne dispose pas de Xcode /
> Swift (compilation et `xcodebuild test` à lancer localement).
