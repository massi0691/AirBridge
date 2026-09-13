//
//  FloatingActionBar.swift
//  AirBridge
//

import SwiftUI

/// Conteneur flottant pour les actions principales d'un écran.
///
/// Les actions restent atteignables quelle que soit la longueur du
/// contenu : posées dans un `safeAreaInset`, elles ne sont jamais
/// repoussées hors de l'écran par la liste qu'elles surplombent.
///
/// Le conteneur ne connaît pas les actions qu'il présente : il ne fait
/// que les habiller, ce qui le rend utilisable par n'importe quel écran.
struct FloatingActionBar<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {

        HStack {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: 16
            )
        )
        .shadow(
            color: .black.opacity(0.15),
            radius: 8,
            y: 2
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
