//
//  AirBridgeColors.swift
//  AirBridge
//
//  Color tokens for AirBridge. All colors are system-driven so Light / Dark /
//  Increase Contrast modes are honoured automatically.
//

import SwiftUI

/// Color tokens used across the AirBridge UI.
///
/// Each color maps to a system semantic color so Light, Dark, and Increase
/// Contrast modes are honoured without us having to redefine palettes. We
/// avoid baking hex values in — they would break the system color contract
/// and force us to maintain a parallel palette.
extension AirBridgeDesign {

    enum Color {

        /// Primary action accent. Resolves to the user's chosen accent
        /// color in system settings.
        static let accent: SwiftUI.Color = .accentColor

        /// Foreground used for primary text and high-emphasis content.
        static let primaryText: SwiftUI.Color = .primary

        /// Foreground for secondary text (timestamps, captions).
        static let secondaryText: SwiftUI.Color = .secondary

        /// Status colors. All four are system-provided for proper
        /// Light/Dark adaptation and accessibility.
        static let success: SwiftUI.Color = .green
        static let warning: SwiftUI.Color = .orange
        static let error:   SwiftUI.Color = .red
        static let info:    SwiftUI.Color = .blue
    }
}