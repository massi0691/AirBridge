//
//  AirBridgeSpacing.swift
//  AirBridge
//
//  Spacing scale. Use these instead of literal numbers so layout is
//  consistent and refactors are cheap.
//

import CoreGraphics

extension AirBridgeDesign {

    /// Spacing tokens in points. The scale is intentionally small:
    /// a 6-step ramp covers the entire UI without burying intent.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    /// Standard corner radii. iOS uses continuous corners on rounded
    /// shapes; macOS uses regular corners. The values are identical —
    /// the rendering difference is applied at the call site.
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
    }

    /// Minimum tap target, per Apple HIG (44pt).
    static let minimumTapTarget: CGFloat = 44
}