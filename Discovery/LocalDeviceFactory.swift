//
//  LocalDeviceFactory.swift
//  AirBridge
//
//  Created by massi9106 on 21/07/2026.
//

import Foundation

#if os(iOS)
import UIKit
#endif

struct LocalDeviceFactory {

    static func make() -> Device {
          let deviceName: String
          let deviceModel: String
          let systemVersion: String

          #if os(macOS)

          deviceName = Host.current().localizedName ?? "Mac"
          deviceModel = "Mac"

          let version = ProcessInfo.processInfo.operatingSystemVersion
          systemVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

          #elseif os(iOS)

          deviceName = UIDevice.current.name
          deviceModel = UIDevice.current.model
          systemVersion = UIDevice.current.systemVersion

          #else

          deviceName = "Appareil Apple"
          deviceModel = "Appareil inconnu"
          systemVersion = "Inconnue"

          #endif

          // La clé publique long-terme est liée à `sender` pour
          // permettre la vérification des messages `hello`,
          // `keyExchange`, `keyExchangeAck`, `acknowledgement`,
          // `ping`, `pong` qui ne transportent pas la clé dans
          // leur payload. Si le Keychain est corrompu ou absent,
          // on continue sans : la chaîne de sécurité tombe en
          // fallback dégradé (les messages sortants ne sont pas
          // signables, les récepteurs les rejetteront). Ce cas
          // ne devrait jamais se produire en pratique — la clé
          // est générée à la première exécution.
          let publicKeyData: Data?
          do {
              let identity = try SecureIdentityStore.ensureIdentity()
              publicKeyData = identity.publicKeyData
          } catch {
              print(
                  "⚠️ LocalDeviceFactory : impossible de charger la clé long-terme — " +
                  "les messages sortants ne pourront pas être signés. " +
                  "Erreur : \(error)"
              )
              publicKeyData = nil
          }

          return Device(
              id: makePersistentID(),
              name: deviceName,
              model: deviceModel,
              systemVersion: systemVersion,
              publicKeyData: publicKeyData
          )
      }

      private static func makePersistentID() -> UUID {
          let key = "airbridge.localDeviceID"

          if let savedID = UserDefaults.standard.string(forKey: key),
             let uuid = UUID(uuidString: savedID) {
              return uuid
          }

          let newID = UUID()
          UserDefaults.standard.set(newID.uuidString, forKey: key)
          return newID
      }
    
#if os(iOS)
private static func deviceIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)

    let mirror = Mirror(
        reflecting: systemInfo.machine
    )

    return mirror.children.reduce(into: "") { identifier, element in
        guard let value = element.value as? Int8,
              value != 0 else {
            return
        }

        identifier.append(
            Character(
                UnicodeScalar(UInt8(value))
            )
        )
    }
}
#endif
    
#if os(iOS)
private static func marketingModel(
    from identifier: String
) -> String {
    switch identifier {
    case "iPhone17,5":
        return "iPhone 16e"

    // On ajoutera les autres modèles progressivement.

    case "x86_64", "arm64":
        return "Simulateur iPhone"

    default:
        return UIDevice.current.model
    }
}
#endif
    
    
}
