//
//  FilePreviewItem.swift
//  AirBridge
//
//  Single file card shown in the share screen's preview grid.
//
//  The card is a pure view : it never reaches into the Core. It
//  receives a URL and renders a system-icon, a name, and a size — no
//  pre-touched file, no pre-read content, no implicit state. The
//  Quick Look thumbnail is generated lazily by the system, so a
//  missing or unreadable file falls back to a generic document icon
//  instead of crashing the grid.
//

import SwiftUI
internal import UniformTypeIdentifiers

/// Single file card.
///
/// Maps the file extension to an SF Symbol via `UTType` so an image
/// shows `photo`, an audio file `music.note`, a PDF `doc.richtext`,
/// etc. Falls back to `doc` when the system cannot resolve a type
/// (e.g. a custom extension).
struct FilePreviewItem: View {

    /// Position in the source list. Used only for the tap-to-remove
    /// callback; the card never mutates the list itself.
    let index: Int
    let url: URL
    let onRemove: (Int) -> Void

    /// True when the tap should ask for confirmation before removing.
    /// `true` keeps the gesture safe when several files are queued;
    /// the lone-file case can afford an immediate removal.
    let confirmRemoval: Bool

    @State private var isConfirmingRemoval = false

    private var fileName: String {
        url.lastPathComponent
    }

    private var fileSize: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values?.fileSize ?? 0)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var typeIcon: String {
        // `UTType(filenameExtension:)` returns `nil` when the system
        // has no entry for the extension. We then fall back to a
        // generic document icon, never a crash.
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              let type = UTType(
                filenameExtension: fileExtension
              ) else {
            return "doc"
        }

        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf)   { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text)  { return "doc.text" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: AirBridgeDesign.Radius.medium
                    )
                    .fill(.regularMaterial)
                    .frame(height: 96)

                    Image(systemName: typeIcon)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        handleTap()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                .white,
                                .black.opacity(0.55)
                            )
                            .padding(AirBridgeDesign.Spacing.xs)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer \(fileName)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(AirBridgeDesign.Typography.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    Text(fileSize)
                        .font(AirBridgeDesign.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        // Each preview slides in from the leading edge when it is
        // added to the selection.
        .transition(Transitions.rowAppear)
        .animation(
            AirBridgeDesign.SpringAnimation.standard,
            value: url
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fichier, \(fileName), \(fileSize)")
        .accessibilityHint("Toucher pour retirer de la sélection")
        .confirmationDialog(
            "Retirer ce fichier ?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Retirer", role: .destructive) {
                onRemove(index)
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text(fileName)
        }
    }

    private func handleTap() {
        if confirmRemoval {
            isConfirmingRemoval = true
        } else {
            onRemove(index)
        }
    }
}
