//
//  AirBridgeTypography.swift
//  AirBridge
//
//  Typography scale. Uses Dynamic Type so all text scales with the user's
//  preferred reading size and is VoiceOver-friendly.
//

import SwiftUI

extension AirBridgeDesign {

    /// Semantic typography roles. Each role maps to a SwiftUI text style,
    /// so Dynamic Type and accessibility sizes work out of the box.
    enum Typography {

        static let largeTitle: Font = .largeTitle
        static let title: Font = .title
        static let title2: Font = .title2
        static let title3: Font = .title3
        static let headline: Font = .headline
        static let body: Font = .body
        static let callout: Font = .callout
        static let subheadline: Font = .subheadline
        static let footnote: Font = .footnote
        static let caption: Font = .caption
        static let caption2: Font = .caption2

        /// Monospaced body for fingerprints, hashes, IDs.
        static let monoCaption: Font = .system(.caption, design: .monospaced)
        static let monoBody: Font = .system(.body, design: .monospaced)
    }
}