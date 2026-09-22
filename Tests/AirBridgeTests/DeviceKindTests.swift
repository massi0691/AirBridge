//
//  DeviceKindTests.swift
//  AirBridgeTests
//
//  Tests de la classification visuelle des appareils (`DeviceKind`).
//
//  Le radar et les listes s'appuient sur cette classification pour
//  choisir l'icône et le label VoiceOver. La règle est volontairement
//  permissive : ce qu'on ne sait pas classer retombe sur `.other` plutôt
//  que de deviner faux — un iPhone affiché avec une icône de Mac est un
//  bug visible, l'inverse aussi.
//

import XCTest
@testable import AirBridge

final class DeviceKindTests: XCTestCase {

    // MARK: - Classification depuis le modèle

    func testClassifiesIPhone() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "iPhone"), .iphone)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "iPhone 16 Pro"), .iphone)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "iphone 13 mini"), .iphone)
    }

    func testClassifiesIPad() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "iPad"), .ipad)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "iPad Air (5th generation)"), .ipad)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "ipad pro"), .ipad)
    }

    func testClassifiesMac() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Mac"), .mac)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "MacBook Pro"), .mac)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Mac mini"), .mac)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "mac"), .mac)
    }

    func testFallsBackToOtherForUnknownModels() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: ""), .other)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Windows PC"), .other)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Pixel 9"), .other)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Appareil inconnu"), .other)
    }

    func testMatchingIsCaseInsensitive() {
        // Les enregistrements TXT Bonjour ne sont pas normalisés en
        // casse : la comparaison ne doit pas en dépendre.
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "IPHONE"), .iphone)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "IPAD"), .ipad)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "MAC"), .mac)
    }

    func testSubstringMatchesWithinLongerModelStrings() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "Mon iPhone de travail"), .iphone)
        XCTAssertEqual(AirBridgeDesign.DeviceKind.from(model: "The new iPad"), .ipad)
    }

    // MARK: - Icônes et accessibilité

    func testSymbolNames() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.iphone.symbolName, "iphone")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.ipad.symbolName, "ipad")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.mac.symbolName, "laptopcomputer")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.other.symbolName, "desktopcomputer")
    }

    func testAccessibilityLabels() {
        XCTAssertEqual(AirBridgeDesign.DeviceKind.iphone.accessibilityLabel, "iPhone")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.ipad.accessibilityLabel, "iPad")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.mac.accessibilityLabel, "Mac")
        XCTAssertEqual(AirBridgeDesign.DeviceKind.other.accessibilityLabel, "Appareil")
    }
}
