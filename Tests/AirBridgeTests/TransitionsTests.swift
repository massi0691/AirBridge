//
//  TransitionsTests.swift
//  AirBridgeTests
//
//  Tests de sanity check sur les transitions et animations
//  exposées par `Transitions` et `AirBridgeDesign.SpringAnimation`.
//
//  Les `AnyTransition` et `Animation` SwiftUI ne sont pas trivialement
//  inspectables (`Mirror` ne révèle pas grand-chose d'utile), donc
//  on vérifie surtout qu'elles se construisent sans crasher et que
//  les noms attendus sont stables.
//
//  Couvre la Phase 5 (présentation visuelle).
//

import XCTest
import SwiftUI
@testable import AirBridge

final class TransitionsTests: XCTestCase {

    /// Chaque transition statique doit être constructible — c'est
    /// trivial puisque ce sont des `let`, mais on vérifie aussi
    /// qu'elles ne sont pas accidentellement `nil` (Swift ne le
    /// permet pas pour `AnyTransition`, mais on documente
    /// l'invariant).
    func testAllTransitionsAreConstructible() {
        let card: AnyTransition = Transitions.cardAppear
        let row: AnyTransition = Transitions.rowAppear
        let alert: AnyTransition = Transitions.alertAppear
        let tab: AnyTransition = Transitions.tabSwitch

        // AnyTransition n'est pas Equatable ; on vérifie seulement
        // qu'on a bien un objet non-nil via sa description.
        XCTAssertFalse(
            String(describing: card).isEmpty,
            "cardAppear doit produire une AnyTransition non-vide."
        )
        XCTAssertFalse(
            String(describing: row).isEmpty,
            "rowAppear doit produire une AnyTransition non-vide."
        )
        XCTAssertFalse(
            String(describing: alert).isEmpty,
            "alertAppear doit produire une AnyTransition non-vide."
        )
        XCTAssertFalse(
            String(describing: tab).isEmpty,
            "tabSwitch doit produire une AnyTransition non-vide."
        )
    }

    /// Les animations spring doivent se construire sans crash et
    /// être comparables en identité (deux `.spring(...)` produits
    /// à des endroits distincts ne sont pas `==`, mais leurs
    /// descriptions ne doivent pas être vides).
    func testSpringAnimationsAreConstructible() {
        let standard: Animation = AirBridgeDesign.SpringAnimation.standard
        let emphasized: Animation = AirBridgeDesign.SpringAnimation.emphasized

        XCTAssertFalse(
            String(describing: standard).isEmpty,
            "standard spring doit produire une Animation non-vide."
        )
        XCTAssertFalse(
            String(describing: emphasized).isEmpty,
            "emphasized spring doit produire une Animation non-vide."
        )
    }
}
