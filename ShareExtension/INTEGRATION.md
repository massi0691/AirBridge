# Intégration Share Extension & Finder Service — Phase 3

## Architecture Générale

```
┌─────────────────────────────────────────────────────────────────┐
│                     Points d'entrée système                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   iOS Share Sheet          macOS Finder Service    macOS Drop   │
│   ┌─────────────┐          ┌─────────────────┐    ┌──────────┐  │
│   │ShareExten- │          │AirBridgeService-│    │DropZone  │  │
│   │sion.swift  │          │  Provider.swift │    │Window.sw │  │
│   └─────┬──────┘          └────────┬────────┘    └────┬─────┘  │
│         │                          │                    │        │
│         └──────────────────────────┼────────────────────┘        │
│                                    ▼                             │
│                         ┌──────────────────┐                    │
│                         │  ShareHelper.swift │                  │
│                         │  - URL Scheme      │                  │
│                         │  - File Provider   │                  │
│                         │  - App Launcher    │                  │
│                         └────────┬─────────┘                    │
│                                  │                              │
│                                  ▼                              │
│                         ┌──────────────────┐                    │
│                         │airbridge://receive│                   │
│                         │    ?files=...     │                   │
│                         └────────┬─────────┘                    │
│                                  │                              │
└──────────────────────────────────┼──────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Application Principale                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   AirBridgeApp                    AirBridgeCore                  │
│   - open(urls:)  ───────────────► importAndRequestItems(urls)  │
│                                  (TransferManager)               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## URL Scheme `airbridge://`

### Format
```
airbridge://receive?files=<url1|url2|url3>
```

Les URLs sont :
1. Encodées en `absoluteString` (file://...)
2. Jointes par `|`
3. Percent-encoded pour les query parameters

### Parsing côté App Principale

```swift
// Exemple d'utilisation
if let urls = AirBridgeURLScheme.parseReceiveURL(url) {
    core.importAndRequestItems(urls: urls)
}
```

## Types de Fichiers Supportés

### iOS Share Extension
- `public.item` — fichiers génériques
- `public.image` — images
- `public.movie` — vidéos
- `public.data` — données
- `public.text` — texte
- `public.url` — URLs web

### Limites
- Maximum 20 fichiers par transfert
- Taille maximale par fichier : 500 Mo

## Configuration Requise

### App Groups (pour extension iOS)
Pour partager des données entre l'extension et l'app principale :
```
group.com.airbridge.shared
```

### URL Scheme Registration

#### iOS — Info.plist
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.airbridge</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>airbridge</string>
        </array>
    </dict>
</array>
```

#### macOS — Info.plist
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.airbridge</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>airbridge</string>
        </array>
    </dict>
</array>
```

### NSServices (macOS Finder)

```xml
<key>NSServices</key>
<array>
    <dict>
        <key>NSMenuItem</key>
        <dict>
            <key>default</key>
            <string>Envoyer avec AirBridge</string>
        </dict>
        <key>NSMessage</key>
        <string>send</string>
        <key>NSPortName</key>
        <string>AirBridge</string>
        <key>NSSendFileTypes</key>
        <array>
            <string>public.item</string>
        </array>
    </dict>
</array>
```

## Flux de Transfert

### 1. Fichiers sélectionnés par l'utilisateur
```
iOS: Share Sheet → Share Extension → NSItemProvider.loadFileRepresentation()
macOS: Finder Service → NSPasteboard.readObjects()
macOS: Drag & Drop → NSDraggingInfo
```

### 2. Extraction des fichiers
```
AirBridgeFileProvider.loadFiles(from:) → [URL] temporaires
```

### 3. Transmission à l'application principale
```
AirBridgeAppLauncher.openMainApp(with:) → airbridge://receive?files=...
```

### 4. Réception par l'application principale
```
AppDelegate.application(_:open:) → AirBridgeURLScheme.parseReceiveURL()
→ core.importAndRequestItems(urls:)
```

### 5. Transfert via le réseau
```
TransferManager → ConnectionManager → Pairage → Transfert
```

## Pré-conditions

Pour qu'un transfert fonctionne :
1. ✅ Les deux appareils doivent être sur le même réseau
2. ✅ L'application principale doit être ouverte (ou se lancer via URL scheme)
3. ✅ Les appareils doivent être pairés et connectés
4. ✅ Le pair doit accepter la demande de transfert

## États d'Erreur

| Erreur | Cause | Action |
|--------|-------|--------|
| `noItemsFound` | Aucun fichier sélectionné | Fermer l'extension |
| `loadFailed` | Fichier inaccessible | Afficher l'erreur |
| `unsupportedType` | Type non supporté | Afficher l'erreur |
| `fileTooLarge` | Fichier > 500 Mo | Afficher l'erreur |

## Tests Recommandés

### iOS
1. Ouvrir Photos → Partager → AirBridge → choisir appareil → transfert
2. Ouvrir Fichiers → Partager un document → même flux
3. Tester avec plusieurs fichiers (5, 10, 20)
4. Tester avec des images de différentes tailles
5. Tester avec des vidéos

### macOS
1. Clic droit sur un fichier → "Envoyer avec AirBridge" → transfert
2. Drag & drop sur l'icône AirBridge dans le Dock → transfert
3. Tester avec plusieurs fichiers
4. Tester avec des dossiers (si supportés)

## Fichiers Créés

### iOS Share Extension
- `ShareExtension/ShareViewController.swift` — Contrôleur principal
- `ShareExtension/Info.plist` — Configuration de l'extension
- `ShareExtension/MainInterface.storyboard` — Interface principale
- `ShareExtension/ShareExtension.entitlements` — Entitlements

### macOS Finder Service
- `MacOS/AirBridgeServiceProvider.swift` — Finder Service
- `MacOS/DropZoneWindow.swift` — Drag & Drop Window

### Partagé
- `ShareExtension/ShareHelper.swift` — Helper centralisé
- `ShareExtension/INTEGRATION.md` — Cette documentation
