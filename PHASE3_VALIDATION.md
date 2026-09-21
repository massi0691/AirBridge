# Phase 3 — Kit de validation Xcode (macOS)

Ce document contient tout ce qu'il faut exécuter sur ton Mac pour valider
la Phase 3. Le code a été réimplémenté et revu statiquement, mais **aucune
compilation réelle n'a pu être effectuée dans l'environnement de
développement** (Linux, sans Xcode) : la validation ci-dessous fait foi.

---

## 0. Récupérer le code

```bash
cd ~/AirBridge            # ton clone local
git fetch origin
git checkout arena/01a0c3a0-airbridge
git log -1 --oneline      # note le SHA, il servira dans le rapport
```

> Si tu as des modifications locales non commitées sur
> `Transfer/NetworkErrorClassifier.swift`, elles doivent être mises de
> côté **sans être perdues** :
>
> ```bash
> git stash push -m "wip NetworkErrorClassifier" -- Transfer/NetworkErrorClassifier.swift
> ```
>
> puis `git stash pop` après la validation.

---

## 1. Compilation réelle (macOS)

Identifier le projet et les schemes :

```bash
find . -maxdepth 3 \( -name "*.xcodeproj" -o -name "*.xcworkspace" \)
xcodebuild -project AirBridge.xcodeproj -list
```

Compiler (app macOS, configuration Debug) :

```bash
xcodebuild \
  -project AirBridge.xcodeproj \
  -scheme AirBridge \
  -configuration Debug \
  -destination 'platform=macOS' \
  build 2>&1 | tee /tmp/airbridge-build.log | tail -40

# Succès attendu : "** BUILD SUCCEEDED **"
grep -c "error:" /tmp/airbridge-build.log   # doit afficher 0
```

En cas d'erreurs : copier **les messages d'erreur complets** (les 5–10
lignes autour de chaque `error:`) et me les transmettre — correction
minimale uniquement, pas de refonte.

### Points à couvrir par le build (déjà vérifiés statiquement)

| Élément | Fichier | Remarque |
|---|---|---|
| `Transfer.State.awaitingConfirmation` | `Transfer/Transfer.swift` | switchs exhaustifs mis à jour partout |
| `TransferStore` / `TransferManager` | `Transfer/` | `markAwaitingConfirmation` + façade |
| Changements `AirBridgeCore` | `Core/AirBridgeCore.swift` | appel après émission du `transferCompleted` |
| `MacTransferWorkspaceView` | `UI/MacTransferWorkspaceView.swift` | `NavigationSplitView`, `Table`, `Material` — macOS 26.5 cible, aucune annotation d'availability nécessaire |
| `PendingShareController` | `Features/Sharing/` | inchangé ; `PendingShareSheetView` extraite en vue partagée |
| `Info.plist` | racine | `CFBundleDocumentTypes` ajouté |
| Conformances `Equatable` | 12 enums | corrige des erreurs de compilation préexistantes sur `main` |

---

## 2. Tests XCTest

```bash
xcodebuild test \
  -project AirBridge.xcodeproj \
  -scheme AirBridge \
  -destination 'platform=macOS' \
  2>&1 | tee /tmp/airbridge-tests.log | tail -40
```

Priorités (dans l'ordre) :

```bash
# Suite ciblée (cycle de confirmation) :
xcodebuild test -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=macOS' \
  -only-testing:AirBridgeTests/TransferConfirmationTests 2>&1 | tail -30
```

1. `TransferConfirmationTests` (nouveau) — les 5 scénarios :
   - **Progression** : `testProgressReachesOneHundredPercentWithoutCompleting`
     (progress == 1.0, state != completed)
   - **Ordre** : `testTransitionOrderTransferringThenAwaitingThenCompleted`
     (transferring → awaitingConfirmation → completed)
   - **ACK retardé** : `testDelayedAcknowledgementKeepsTransferUnfinished`
   - **Échec validation** : `testReceiverValidationFailureMarksFailedNotCompleted`
   - **Annulation** : `testAwaitingConfirmationRemainsCancellable`
2. `PendingShareControllerTests`
3. `TransferViewModelTests`
4. Suite complète (`xcodebuild test` sans filtre)

Consigner : `X tests passed, X failed, X skipped` + la liste exacte des
échecs éventuels.

---

## 3. Lancement et validation UI macOS

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/airbridge-dd build
open /tmp/airbridge-dd/Build/Products/Debug/AirBridge.app
```

### 3.1 Fenêtre

- [ ] Taille initiale proche de **1280 × 820** (`defaultSize`)
- [ ] Redimensionnement fluide, aucune vue coupée
- [ ] Sidebar repliable et utilisable

### 3.2 Sidebar

- [ ] Résumé de connexion : nom de l'appareil lié, modèle,
      badge « Session sécurisée » (vert) ou avertissement
- [ ] Sans appareil : « Aucun appareil connecté » + indication
- [ ] Filtres **En cours / Tous / Historique** avec badges de compte
- [ ] Comportement correct au redimensionnement

### 3.3 Zone de dépôt

- [ ] Zone clairement identifiable (Material régulier + bordure pointillée)
- [ ] Bouton **« Choisir des fichiers… »** fonctionnel (ouvre l'ouverture
      de fichiers) — désactivé sans appareil connecté, avec légende
      « Connectez un appareil pour envoyer »
- [ ] Material correctement rendu en clair et en sombre

### 3.4 Tableau des transferts

Colonnes : `Fichier | Appareil | Progression | Débit | État | Action`

- [ ] Lignes lisibles quand la fenêtre change de taille
- [ ] Bouton Annuler (transfert actif **et** en validation)
- [ ] Bouton Reprendre (transfert interrompu)
- [ ] État vide (« Aucun transfert ») quand la liste est vide

### 3.5 États visuels — le point essentiel

Envoyer un fichier et observer :

```
En attente → En cours (0…99 %) → 100 % — Validation du récepteur… → Réussi
```

- [ ] À **100 %** pendant la validation : badge **bleu** « Validation du
      récepteur » avec icône bouclier — **jamais de vert**
- [ ] « Réussi » (vert, coche) n'apparaît qu'après confirmation finale
      (réception du `transferSucceeded`)
- [ ] Vérifier aussi sur l'interface iPhone (`MainView`) : mêmes libellés

Scénario d'échec : couper le récepteur pendant la validation → après le
timeout (30 s), la ligne passe à « Échec » (pas de « Réussi »).

### 3.6 Mode clair / sombre

Réglages Système → Apparence :

- [ ] Light : lisibilité du texte, bordures, Material, badges, tableau
- [ ] Dark : idem — aucun texte illisible, aucune couleur codée en dur
      (tokens `AirBridgeDesign.Color` système partout)

### 3.7 Reduce Motion

Réglages Système → Accessibilité → Affichage → **Réduire les mouvements** :

- [ ] L'animation de la zone de dépôt (survol) est désactivée
      (`accessibilityReduceMotion` respecté)
- [ ] Aucune animation excessive ou obligatoire ailleurs

### 3.8 Non-régression (rapide)

- [ ] Découverte / radar (depuis l'iPhone)
- [ ] Connexion sécurisée
- [ ] Sélection de fichier, drag & drop, envoi, réception
- [ ] Historique, annulation, reprise, réglages
- [ ] Partage Finder (FinderService)

---

## 4. Flux iOS : Fichiers → AirBridge

Cible iOS (simulateur ou iPhone réel — l'App Group exige un appareil réel
pour la Share Extension ; le chemin `file://` fonctionne au simulateur) :

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Scénario : app Fichiers → sélectionner un fichier → bouton Partager →
**AirBridge** (Share Extension), et séparément : touche longue →
**« Ouvrir avec AirBridge »** (CFBundleDocumentTypes, `file://`).

### A. AirBridge complètement fermée

- [ ] Le lot est copié dans `PendingShares/<UUID>/` (App Group)
- [ ] À l'ouverture de l'app : récupération du manifeste, affichage du
      fichier dans la feuille d'envoi
- [ ] Absence de duplication (signature du lot)

### B. AirBridge déjà ouverte

- [ ] Notification Darwin / `scenePhase` → feuille présentée
- [ ] Aucun second `PendingShare`, aucun doublon
- [ ] Flux existant conservé (choix du destinataire, envoi explicite)

### C. Multi-fichiers + noms spéciaux

- [ ] Plusieurs fichiers en un lot : un seul lot, tous présentés
- [ ] Fichiers avec espaces, accents, caractères spéciaux :
      nom / extension / taille corrects, pas de corruption
- [ ] Purge uniquement après livraison confirmée (transfert `completed`)

### Limitation documentée (conforme aux API publiques)

iOS **n'autorise pas** une Share Extension à ouvrir automatiquement
l'application conteneur : `UIApplication.shared` / chaîne de responders /
API privée sont proscrits (et non introduits ici). Le comportement
implémenté est conforme :

1. l'extension copie le lot dans l'App Group et poste la notification
   Darwin `com.airbridge.share.pending` ;
2. l'URL scheme `airbridge://receive?batch=` est demandée quand le
   système le permet ;
3. à défaut (app fermée), le lot est récupéré au prochain démarrage /
   retour au premier plan (`sweepPendingShares`).

Une interaction utilisateur (ouverture de l'app) peut donc être nécessaire
— c'est une restriction d'iOS, pas un défaut d'implémentation.

---

## 5. Rapport attendu

Remplir et renvoyer :

```text
Build   : SUCCESS / FAILED  (coller les erreurs si FAILED)
Tests   : X passed / X failed (liste des échecs)

Transfert (cycle réel) :
  transferring → awaitingConfirmation → completed : OK/KO
  100 % — Validation du récepteur… ≠ Réussi        : OK/KO
  Échec validation (pas de vert)                   : OK/KO
  Annulation pendant validation                    : OK/KO

macOS : lancement / fenêtre 1280×820 / sidebar / tableau / drag & drop /
        Light-Dark / Reduce Motion → OK/KO chacun

iOS   : Fichiers → AirBridge (fermée / ouverte / multi-fichiers / noms
        spéciaux) → OK/KO chacun

Problèmes restants : liste factuelle
```

**PHASE 3 VALIDÉE** uniquement si : build SUCCESS, tests passent (ou
échecs documentés), cycle de confirmation vérifié en réel, interface
macOS lancée et conforme, flux Fichiers vérifié autant que l'environnement
le permet, aucune API privée introduite.
