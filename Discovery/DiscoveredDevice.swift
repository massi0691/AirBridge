//
//  DiscoveryDevice.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation
import Network

struct DiscoveredDevice: Identifiable {
    let device: Device
    let endpoint: NWEndpoint

    /// Force du signal Bonjour, en dBm (négatif, proche de 0 = fort).
    ///
    /// Network.framework ne fournit pas de RSSI direct via
    /// `NWBrowser.Result.metadata` (contrairement à CoreBluetooth) :
    /// on ne peut donc pas l'extraire des TXT records. Ce champ reste
    /// `nil` tant qu'on n'a pas une source de signal exploitable, et la
    /// vue radar retombe alors sur le placement par hash tout en
    /// signalant visuellement l'absence de métrique.
    let rssi: Int?

    init(
        device: Device,
        endpoint: NWEndpoint,
        rssi: Int? = nil
    ) {
        self.device = device
        self.endpoint = endpoint
        self.rssi = rssi
    }

    var id: UUID {
        device.id
    }
}
