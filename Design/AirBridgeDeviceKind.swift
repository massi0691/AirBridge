//
//  AirBridgeDeviceKind.swift
//  AirBridge
//
//  Maps a Device.model string to the appropriate SF Symbol and an
//  accessibility label. The radar and device lists use this to render
//  avatars that respect the actual platform (iPhone / iPad / Mac / other).
//

import Foundation

extension AirBridgeDesign {

    /// Visual classification of a discovered device.
    enum DeviceKind {

        case iphone
        case ipad
        case mac
        case other

        /// SF Symbol used for the avatar.
        var symbolName: String {
            switch self {
            case .iphone: "iphone"
            case .ipad:   "ipad"
            case .mac:    "laptopcomputer"
            case .other:  "desktopcomputer"
            }
        }

        /// Human-readable label for VoiceOver.
        var accessibilityLabel: String {
            switch self {
            case .iphone: "iPhone"
            case .ipad:   "iPad"
            case .mac:    "Mac"
            case .other:  "Appareil"
            }
        }

        /// Derives a kind from the `model` string the Bonjour TXT record
        /// carries. The mapping is intentionally lenient: anything we can't
        /// classify falls back to `.other` rather than guessing wrong.
        static func from(model: String) -> DeviceKind {
            let lower = model.lowercased()
            if lower.contains("iphone") { return .iphone }
            if lower.contains("ipad")   { return .ipad }
            if lower.contains("mac")    { return .mac }
            return .other
        }
    }
}