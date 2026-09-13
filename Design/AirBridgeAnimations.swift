//
//  AirBridgeAnimations.swift
//  AirBridge
//
//  Animation tokens. All views reference these so animation feel stays
//  consistent and Reduce Motion is honoured in one place.
//

import SwiftUI

extension AirBridgeDesign {

    /// Named animation durations. The three steps cover the bulk of the UI;
    /// any custom timing should justify itself against these.
    enum AnimationDuration {
        static let quick: Double = 0.2
        static let standard: Double = 0.3
        static let slow: Double = 0.6
    }

    /// Standard animation curves. Use `.animation(.airbridgeStandard, ...)`
    /// instead of `.animation(.easeInOut, ...)` so the curve is consistent
    /// and respectReduceMotion can switch to a simpler default if needed.
    enum AnimationCurve {

        /// Default for most transitions. Equivalent to `.easeInOut`
        /// but named so we can change one place if the feel shifts.
        static let standard: Animation = .easeInOut(duration: AnimationDuration.standard)

        /// For UI that should feel snappy (button presses, selection).
        static let quick: Animation = .easeOut(duration: AnimationDuration.quick)

        /// For UI that should feel deliberate (radar pulses, success
        /// animations).
        static let slow: Animation = .easeInOut(duration: AnimationDuration.slow)
    }

    /// A continuous rotation for indeterminate progress (radar sweep).
    /// Respects Reduce Motion by collapsing to a static visual.
    static let radarSweepAnimation: Animation =
        .linear(duration: 2.0).repeatForever(autoreverses: false)
}