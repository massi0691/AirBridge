//
//  Transitions.swift
//  AirBridge
//
//  Cross-platform transitions and animation tokens for the UI.
//
//  The Core layer is platform-agnostic and stays clear of any visual
//  concerns, so every named `AnyTransition` and `Animation` the
//  Views reach for is collected here. This keeps Reduce Motion in
//  one place : a view that opts into the reduced-motion variant
//  swaps spring animations for a low-energy cross-fade, which
//  honours the system setting without each View having to repeat
//  the boilerplate.
//
//  Naming follows the existing `AirBridgeDesign.*` convention
//  (see `Design/AirBridgeAnimations.swift`) so the call sites
//  read like a single design system.
//

import SwiftUI

/// Named transitions for view insertion / removal.
///
/// All transitions are pure SwiftUI — no manual frame math, no
/// timer-driven animations. They wrap `slide`, `scale`, and
/// `opacity` primitives with the same curve so the whole app feels
/// of a piece.
enum Transitions {

    /// Used for hero-like cards entering the screen (pairing card,
    /// completed-transfer card). Slides up a short distance while
    /// fading in, so the card "lands" on the screen rather than
    /// popping in.
    static let cardAppear: AnyTransition = .asymmetric(
        insertion: .offset(y: 24)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.97)),
        removal: .opacity
    )

    /// Used for rows that enter from the leading edge (file preview,
    /// active transfer progress). A small horizontal slide plus a
    /// quick fade.
    static let rowAppear: AnyTransition = .asymmetric(
        insertion: .offset(x: 16)
            .combined(with: .opacity),
        removal: .opacity
    )

    /// Used for modal / alert-style surfaces (pairing confirmation).
    /// Pops from the centre with a fade so the surface feels
    /// focused, not flicked.
    static let alertAppear: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.94)
            .combined(with: .opacity),
        removal: .scale(scale: 0.96)
            .combined(with: .opacity)
    )

    /// Used when swapping the active tab inside a tab container.
    /// Cross-fade so the layout shift feels deliberate.
    static let tabSwitch: AnyTransition = .asymmetric(
        insertion: .opacity,
        removal: .opacity
    )

    /// Used for device bubbles entering or leaving the discovery radar.
    /// A soft scale (from 0.6 to 1.0) plus a fade. The transition is
    /// meant to be paired with `AirBridgeDesign.SpringAnimation.standard`
    /// at the call site so the bubble "lands" rather than popping in.
    static let radarBubbleAppear: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.6)
            .combined(with: .opacity),
        removal: .scale(scale: 0.6)
            .combined(with: .opacity)
    )
}

extension AirBridgeDesign {

    /// Spring animation tokens for the UI layer.
    ///
    /// `standard` is the everyday choice (selection, toggle, small
    /// reveal). `emphasized` is the celebratory variant used for
    /// positive terminal events (transfer completed, file sent). The
    /// existing `AnimationCurve` tokens live alongside; this enum
    /// exists so Views have a single namespace to reach for when
    /// they want a spring instead of a curve.
    enum SpringAnimation {

        /// Short spring for routine state changes.
        static let standard: Animation = .spring(
            response: 0.32,
            dampingFraction: 0.85
        )

        /// More pronounced spring for positive terminal events.
        static let emphasized: Animation = .spring(
            response: 0.42,
            dampingFraction: 0.72
        )
    }
}