//
//  FilePreviewGrid.swift
//  AirBridge
//
//  Grid of file previews for the share screen.
//
//  Renders the URLs the ViewModel has attached as a `LazyVGrid` of
//  `FilePreviewItem`. The grid is purely presentational : it
//  forwards the tap-to-remove to the ViewModel and reads the URL
//  list from it. No business logic, no file I/O.
//

import SwiftUI

/// Grid of file previews.
///
/// Adapts to the available width via a `LazyVGrid` with adaptive
/// columns so an iPhone shows 2 columns, an iPad 3 or 4, and a Mac
/// window as many as the user resizes in.
struct FilePreviewGrid: View {

    let urls: [URL]
    let onRemove: (Int) -> Void

    /// True when the tap-to-remove should ask for confirmation. The
    /// first file (lone-file case) can be removed without warning;
    /// any subsequent file triggers a destructive dialog so a stray
    /// tap doesn't lose a queued file silently.
    private func confirmRemoval(at index: Int) -> Bool {
        urls.count > 1
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: 120,
                maximum: 180
            ),
            spacing: AirBridgeDesign.Spacing.sm
        )]
    }

    var body: some View {
        if urls.isEmpty {
            emptyState
        } else {
            LazyVGrid(
                columns: columns,
                spacing: AirBridgeDesign.Spacing.sm
            ) {
                ForEach(
                    Array(urls.enumerated()),
                    id: \.element
                ) { index, url in
                    FilePreviewItem(
                        index: index,
                        url: url,
                        onRemove: onRemove,
                        confirmRemoval: confirmRemoval(at: index)
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Aucun fichier sélectionné")
                .font(AirBridgeDesign.Typography.callout)
                .foregroundStyle(.secondary)
            Text("Ajoute des fichiers pour les envoyer à l'appareil connecté.")
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AirBridgeDesign.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AirBridgeDesign.Spacing.xl)
    }
}
