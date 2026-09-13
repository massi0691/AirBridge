//
//  Haptics.swift
//  AirBridge
//
//  Cross-platform haptics abstraction.
//
//  The Core layer is platform-agnostic, so haptic feedback has to be
//  invoked from the UI side. To keep the Views free of conditional
//  `#if os(iOS)` blocks and to keep a single point of policy, every
//  haptic call routes through this enum.
//
//  Platform behaviour:
//   - iOS : real `UIKit` feedback generators, prepared once and reused
//     so the latency between the user's gesture and the taptic engine
//     stays minimal.
//   - macOS, visionOS : no-op. Most Macs don't have reliable haptic
//     hardware, and visionOS gestures are surfaced through its own
//     visual feedback; the visual + audio layer is sufficient on those
//     platforms.
//
//  Views must never instantiate a `UIImpactFeedbackGenerator` or its
//  peers directly — they always go through `Haptics.*`.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// UI haptic feedback surface.
///
/// All entry points are `@MainActor` because the underlying
/// `UIImpactFeedbackGenerator` family must be driven from the main
/// thread. Views are already main-actor by default, so this matches
/// the existing call sites.
@MainActor
enum Haptics {

    /// Impact strength variants, mirroring `UIImpactFeedbackGenerator.FeedbackStyle`.
    enum Style {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    // MARK: - Generators

    #if os(iOS)
    /// Shared selection generator. Cheap to allocate but worth
    /// caching because the Core Animation haptic engine needs a few
    /// frames to "warm up".
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    /// Shared impact generator, prepared on first use for the most
    /// common style (`.medium`). Other styles get their own generator
    /// lazily so we don't pay for what we don't use.
    private static var impactGenerators: [Style: UIImpactFeedbackGenerator] = [:]
    /// Shared notification generator, reused across all
    /// `success` / `warning` / `error` calls.
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    // MARK: - Public API

    /// Light tap used for a discrete selection (toggle, picker, tab).
    static func selection() {
        #if os(iOS)
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
        #endif
    }

    /// Impact tap. Use the lightest style that still reads; don't
    /// default to `.heavy` for routine actions.
    static func impact(_ style: Style = .medium) {
        #if os(iOS)
        let generator = impactGenerator(for: style)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// Success notification (positive terminal event: share
    /// accepted, transfer finished).
    static func success() {
        #if os(iOS)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.success)
        #endif
    }

    /// Warning notification (neutral / cautionary terminal event:
    /// user-initiated cancellation, blocked peer).
    static func warning() {
        #if os(iOS)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.warning)
        #endif
    }

    /// Error notification (negative terminal event: failed
    /// transfer, rejected request).
    static func error() {
        #if os(iOS)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.error)
        #endif
    }

    // MARK: - Helpers

    #if os(iOS)
    /// Lazily allocates an `UIImpactFeedbackGenerator` per style.
    /// The generator is cached so subsequent calls reuse the same
    /// instance and benefit from `prepare()`.
    private static func impactGenerator(
        for style: Style
    ) -> UIImpactFeedbackGenerator {
        if let cached = impactGenerators[style] {
            return cached
        }
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light:  uiStyle = .light
        case .medium: uiStyle = .medium
        case .heavy:  uiStyle = .heavy
        case .soft:   uiStyle = .soft
        case .rigid:  uiStyle = .rigid
        }
        let generator = UIImpactFeedbackGenerator(style: uiStyle)
        impactGenerators[style] = generator
        return generator
    }
    #endif
}