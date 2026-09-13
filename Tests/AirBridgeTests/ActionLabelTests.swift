import XCTest
@testable import AirBridge

/// Vérifie les intitulés des actions principales.
///
/// La barre elle-même ne s'interroge pas sans hôte graphique ; ce qui est
/// vérifiable, c'est le texte choisi pour chaque largeur, et c'est là que se
/// joue la lisibilité sur iPhone.
final class ActionLabelTests: XCTestCase {

    // MARK: - Version compacte

    func testCompactTitlesAreTheSpecifiedSingleWords() {

        XCTAssertEqual(ActionLabel.file.title(.compact), "Fichier")
        XCTAssertEqual(ActionLabel.folder.title(.compact), "Dossier")
        XCTAssertEqual(ActionLabel.disconnect.title(.compact), "Déco")
    }

    func testFullTitlesKeepTheExplicitWording() {

        XCTAssertEqual(
            ActionLabel.file.title(.full),
            "Choisir un fichier"
        )

        XCTAssertEqual(
            ActionLabel.folder.title(.full),
            "Choisir un dossier"
        )

        XCTAssertEqual(
            ActionLabel.disconnect.title(.full),
            "Déconnecter"
        )
    }

    // MARK: - Ce qui doit rester vrai pour toute action

    func testCompactTitleIsNeverLongerThanTheFullOne() {

        for label in ActionLabel.allCases {

            XCTAssertLessThanOrEqual(
                label.title(.compact).count,
                label.title(.full).count,
                "L'intitulé court de \(label) dépasse l'intitulé complet"
            )
        }
    }

    func testCompactTitleIsASingleWord() {

        // Trois boutons doivent tenir sur une ligne d'iPhone : un intitulé
        // en deux mots ferait revenir la troncature que l'on corrige.
        for label in ActionLabel.allCases {

            XCTAssertFalse(
                label.title(.compact).contains(" "),
                "L'intitulé court de \(label) tient sur plusieurs mots"
            )
        }
    }

    func testNoTitleIsEmpty() {

        for label in ActionLabel.allCases {

            for width in [ActionLabelWidth.compact, .full] {

                XCTAssertFalse(
                    label.title(width).isEmpty,
                    "\(label) n'a pas d'intitulé en largeur \(width)"
                )
            }
        }
    }

    func testEveryActionKeepsAnIconOnBothWidths() {

        // L'icône porte le sens quand le texte est réduit : elle ne doit
        // manquer à aucune action.
        for label in ActionLabel.allCases {

            XCTAssertFalse(
                label.systemImage.isEmpty,
                "\(label) n'a pas d'icône"
            )
        }
    }

    func testIconsAreDistinctAcrossActions() {

        // Deux actions partageant une icône seraient indiscernables en
        // version compacte.
        let icons = ActionLabel.allCases.map(\.systemImage)

        XCTAssertEqual(
            icons.count,
            Set(icons).count,
            "Deux actions partagent la même icône"
        )
    }

    func testTitlesAreDistinctWithinEachWidth() {

        for width in [ActionLabelWidth.compact, .full] {

            let titles = ActionLabel.allCases.map {
                $0.title(width)
            }

            XCTAssertEqual(
                titles.count,
                Set(titles).count,
                "Deux actions partagent un intitulé en largeur \(width)"
            )
        }
    }

    // MARK: - Cible tactile

    func testTapTargetMeetsTheAccessibilityMinimum() {

        XCTAssertGreaterThanOrEqual(
            ActionLabelMetrics.minimumTapTarget,
            44
        )
    }
}
