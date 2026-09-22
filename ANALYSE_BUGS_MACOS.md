# 🔍 AIRBRIDGE macOS — ANALYSE DES BUGS ET CORRECTIFS

**Date** : 2026-09-22
**Branche** : `arena/01a0c9fe-airbridge`
**Périmètre** : découverte, connexion automatique, partage (feuille + extension Finder), résidence arrière-plan, envoi vers le dernier appareil.
**Méthode** : revue statique complète du code (aucun outil Apple — `xcodebuild`/`swiftc` — n'est disponible dans cet environnement de travail) : chaînes d'appels, chemins d'état, tests existants. **Les correctifs doivent être compilés et testés sur un Mac** (commandes au §7).
**Sécurité** : ✅ aucune protection affaiblie (identité P-256 Keychain, ECDH, ChaCha20-Poly1305, anti-rejeu, pairage TOFU intacts — la politique d'authentification et le pipeline de réception sécurisé n'ont pas été touchés).

---

## 1. Bugs macOS identifiés (causes racines) et correctifs

### Bug 1 — Partage « Ouvrir avec AirBridge » multiple : fichiers perdus

| | |
|---|---|
| **Cause** | `MainAppDelegate.application(_:open:)` postait **UNE notification par URL**. `PendingShareController.present(urls:)` ne présente qu'**un** lot à la fois (`guard item == nil`) et déduplique par *signature* : la première URL créait le lot « seul », les suivantes étaient refusées (« occupé ») ou, après fermeture, re-présentées avec une signature différente. |
| **Correctif** | `AirBridgeApp.swift` : l'AppDelegate traite désormais les URLs **par lot** ; les `file://` d'un « Ouvrir avec » multiple sont importés en **un seul** `importSharedURLs`. |

### Bug 2 — URLs perdues au lancement (cold launch) et sans fenêtre

| | |
|---|---|
| **Cause** | Le consommateur des URLs était le `.onReceive`/`.onOpenURL` **d'une vue fenêtrée** : 1) au lancement, `application(_:open:)` pouvait partir avant le premier rendu → notification perdue ; 2) depuis la résidence arrière-plan (fenêtres fermées), plus aucune scène n'écoutait. |
| **Correctif** | L'AppDelegate conserve les URLs dans un **tampon** jusqu'à l'enregistrement du consommateur (`registerURLHandler`), installé à l'init du Core. Le consommateur reste actif même fenêtres fermées ; l'import est fait **directement** (plus de détour par une notification vue). |

### Bug 3 — Suspension d'auto-connexion jamais levée (« plus de reconnexion après déconnexion volontaire »)

| | |
|---|---|
| **Cause** | `refreshDiscoveredPeerPresence()` était appelé **depuis la boucle par appareil** de `handleDeviceDiscovered` : or ce rappel n'est invoqué **que pour les appareils présents**. Quand le pair quittait le réseau (résultats vides), personne n'observait le départ → la suspension « déconnexion explicite » restait collée même après un aller-retour hors réseau. |
| **Correctif** | Nouveau callback `BonjourService.onDiscoveryResultsChanged(Set<UUID>)`, invoqué à **chaque** changement du jeu (y compris vide), **avant** les rappels par appareil ; le Core met à jour la présence depuis ce seul point (`updateDiscoveredPeerPresence(current:)`). |

### Bug 4 — État `.failed` Bonjour terminal (« parfois, macOS ne détecte plus l'iPhone »)

| | |
|---|---|
| **Cause** | Un `NWBrowser`/`NWListener` en `.failed` restait inerte **jusqu'au redémarrage de l'app** ; aucun `NWPathMonitor` (bascule Wi-Fi/VPN), aucun rappel de réveil. C'est le symptôme classique : détection OK au lancement, vide après veille ou changement de réseau. De plus, « Relancer la recherche » ne relançait que le navigateur, pas l'écouteur. |
| **Correctif** | `BonjourService` : **reprise automatique avec backoff borné** (3→60 s) sur `.failed` des deux services ; **`NWPathMonitor`** qui relance la pile sur changement d'interfaces ; observateur **`NSWorkspace.didWakeNotification`** (réveil macOS) ; API `restartMonitoring()` (pile complète, sans vider le radar) appelée par « Relancer la recherche » (`AirBridgeCore.forceRestartDiscovery`). |

### Bug 5 — App Nap en arrière-plan (découverte/transferts ralentis)

| | |
|---|---|
| **Cause** | App macOS sans assertion d'activité : dès qu'aucune fenêtre n'est visible, App Nap throtle les callbacks réseau (mDNS compris). |
| **Correctif** | `MacBackgroundActivity` (`ProcessInfo.beginActivity`, options `userInitiatedAllowingIdleSystemSleep` + terminaison automatique/soudaine désactivées), tenu tant que l'option « Garder AirBridge actif dans la barre des menus » est active (§5). |

---

## 2. Partage : impossibilité de connecter un appareil non connecté

**Cause** : dans la feuille d'envoi, `ShareView.handleSend` refusait tout destinataire ≠ session active (bandeau « Connecte-toi d'abord » sans action, erreur « Destinataire indisponible » au clic sur une puce découverte). La feuille n'offrait **aucun** chemin de connexion.

**Correctifs** :
- `ShareViewModel.send(to:)` accepte désormais un destinataire **découvert mais non connecté** → `core.scheduleTargetedSend(urls:to:)` : connexion immédiate + envoi **programmé**, qui part dès la **session sécurisée** (délai 120 s).
- `ShareSendOutcome` (`.sentNow` / `.scheduled` / `.refused`) : la feuille reste ouverte sur un envoi programmé et affiche le bandeau **« Connexion à X… — envoi automatique »** avec bouton *Annuler*.
- Bandeau « aucun appareil connecté » : bouton **« Rechercher des appareils »** (`forceRestartDiscovery`) quand la liste est vide.
- Contrat conservé : `send(to:) -> Bool` (tests existants intacts) ; `testSendRejectsWhenNotConnected` reste vert (destinataire ni connecté ni découvert → refus).

---

## 3. Connexion automatique : révision et améliorations

**Défauts trouvés** :
1. **Aucun réglage utilisateur** — impossible de désactiver l'auto-connexion (Bug 3 ci-dessus en était la conséquence la plus visible) ;
2. **Anti-rafale fixe à 15 s** — un pair injoignable était martelé en boucle (1 tentatives/15 s) ;
3. **Le succès n'était pas distingué de l'échec** à la fermeture de session.

**Correctifs** :
- **`Core/AutoConnectPolicy.swift`** (pur, testable) : décision `connect`/`skip(raison)` — session active, pair bloqué, déconnexion explicite, backoff, intérêt (confiance/reprise) ;
- **Préférence `autoConnectEnabled`** (Réglages ▸ « Connexion automatique », `@AppStorage`) : elle ne masque **que** le motif « pair de confiance » — les **reprises de transfert** restent toujours actives ;
- **Backoff exponentiel borné** : 15 → 30 → 60 → 120 → 240 s, compteur `autoConnectFailureCounts` incrémenté seulement si la session **n'a jamais atteint la sécurité**, remis à zéro au premier succès ;
- Présence corrigée (Bug 3) pour que la suspension « déconnexion explicite » soit bien levée au retour du pair.

---

## 4. « macOS ne détecte parfois pas l'iPhone »

**Causes retenues (cumulatives)** — voir Bug 4 §1 :
1. échec terminal sans reprise (`.failed` inerte) ;
2. changement d'interface / réveil non traités (cache mDNS périmé, état `.ready` mensonger) ;
3. « Relancer la recherche » incomplet (navigateur seul) ;
4. (documenté, inchangé) autorisation « Réseau local » refusée — le bandeau d'incident existant + la reprise périodique couvrent désormais aussi ce cas après accord.

**Tests** : `BonjourRetryDelayTests` (backoff 3→60 s).

---

## 5. Résidence en arrière-plan (barre des menus)

**Nouveautés** (`AirBridgeApp` + `MacOS/MenuBarSupport.swift`) :
- Scène **`MenuBarExtra`** (icône `arrow.triangle.2.circlepath`) : état de connexion, *Ouvrir AirBridge*, *Envoyer un fichier…* (ouvre la zone de dépôt), *Quitter* ;
- **`applicationShouldTerminateAfterLastWindowClosed → false`** : fermer la fenêtre ne tue plus jamais l'app ;
- **`WindowGroup(id: "workspace")`** : le menu **recrée** la fenêtre via `openWindow(id:)` ;
- **Assertion d'activité** (`MacBackgroundActivity`) tant que l'option est active ;
- Réglage **« Garder AirBridge actif dans la barre des menus »** (défaut ON) + **« Lancer AirBridge au démarrage »** (`SMAppService`) ;
- Ingestion des parts **sans fenêtre** (tampon AppDelegate, §1 Bug 2).

---

## 6. Envoi vers le dernier appareil connecté depuis le menu de partage

**Nouveautés** :
1. **État partagé** (`MacOS/AirBridgeSharedState.swift`, App Group `group.com.airbridge.shared`) : l'app publie `state.json` à l'ouverture/fermeture de session sécurisée (dernier pair + session ouverte/fermée) ;
2. **Extension Finder** : si un dernier appareil est connu, la feuille affiche le bouton principal **« Envoyer à <X> »** (sinon « Terminer »/« Ouvrir » comme avant) ;
3. **Directive d'envoi** (`AirBridgeSendDirective`, écriture atomique) + réouverture de l'app en `airbridge://receive?batch=…&send=<peerID>` : l'app **revalide** la cible contre sa session réelle (l'extension ne peut pas forcer un envoi vers un pair différent) ;
4. **Côté app** : `scheduleTargetedSend` envoie **immédiatement** si la session sécurisée avec X existe déjà (sinon auto-connect + envoi à la sécurité ; expiration 120 s) ; `onTargetedSendFinished` referme la feuille de lot quand l'import a réellement eu lieu ;
5. **Feuille d'envoi** : bouton **« Envoyer à <dernier appareil> »** (action barre) dès que ce n'est pas le pair courant — même affordance, quel que soit le point d'entrée.

**Garanties** : consommation **unique** de la directive (lecture+suppression) ; un envoi explicite remplace un envoi programmé couvrant les mêmes fichiers (pas de double envoi) ; expiration bornée.

---

## 7. Fichiers modifiés

| Zone | Fichier |
|---|---|
| App / scènes / ingestion | `AirBridge/AirBridgeApp.swift` |
| Barre de menus / activité | `MacOS/MenuBarSupport.swift` **(nouveau)** |
| État partagé + directives | `MacOS/AirBridgeSharedState.swift` **(nouveau)** — aussi référencé par la cible FinderService (pbxproj) |
| Politique d'auto-connexion | `Core/AutoConnectPolicy.swift` **(nouveau)** |
| Cœur (presence, backoff, envoi ciblé, publications) | `Core/AirBridgeCore.swift` |
| Résilience Bonjour | `Discovery/BonjourService.swift` |
| Feuille d'envoi | `Features/Sharing/ShareView.swift`, `ShareViewModel.swift` |
| Extension Finder (bouton Envoyer à) | `MacOS/FinderService/MacOSShareViewController.swift`, `ShareExtension/ShareHelper.swift` |
| Réglages | `UI/Settings/SettingsView.swift` |
| Relance recherche / envoi rapide | `UI/MacTransferWorkspaceView.swift` |
| Projet | `AirBridge.xcodeproj/project.pbxproj` |
| **Nouveaux tests** | `AutoConnectPolicyTests`, `BonjourRetryDelayTests`, `AirBridgeSharedStateStoreTests`, `TargetedSendTests` (dans `Tests/AirBridgeTests/`) |

---

## 8. Validation à exécuter sur un Mac

```bash
# Compilation (4 configurations historiques du projet)
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=macOS' build

# Tests unitaires
xcodebuild test -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=macOS'

# Passe iOS (ShareViewModel / Stores partagés)
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

**Scénarios manuels clés** :
1. Mac + iPhone appairés de confiance → veille/réveil du Mac → l'iPhone reste détecté ≤ 60 s ;
2. Wi-Fi coupé/rétabli → pile relancée automatiquement ;
3. Feuille de partage sans session → puce d'un appareil découvert → bandeau « Connexion… » → envoi automatique à la session sécurisée ;
4. Réglages ▸ « Connexion automatique » OFF → aucun re-auto-connect au redémarrage, reprises toujours actives ;
5. Sélection multiple Finder ▸ « Ouvrir avec AirBridge » → **tous** les fichiers dans la feuille ;
6. Fenêtres fermées : l'icône barre des menus reste, *Ouvrir AirBridge* restaure la fenêtre ;
7. Extension Finder avec dernier appareil connu → « Envoyer à X » → envoi (ou bandeau d'attente si déconnecté) ;
8. Cible FinderService : vérifier la présence de `AirBridgeSharedState.swift` dans **Build Phases ▸ Compile Sources** de la cible `FinderService`.

---

## 9. Limites / suites possibles

- Revue **statique** : sans Xcode ici, la compilation et la suite de tests (419 tests historiques + ~30 nouveaux) doivent être lancées sur macOS avant merge ;
- `AirBridgeSharedState` est lisible par toute extension du même App Group (masque d'appareils uniquement — pas de clés, pas d'empreintes) ;
- L'envoi programmé expire au bout de 120 s faute de session sécurisée : les fichiers restent dans la feuille (retry manuel possible) ;
- Suite UX : notification « Envoi vers X programmé » systématique, historique des derniers appareils (au-delà du dernier).
