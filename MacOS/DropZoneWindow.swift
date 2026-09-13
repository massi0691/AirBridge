//
//  DropZoneWindow.swift
//  AirBridge
//
//  Drop window for receiving files via drag & drop.
//  The user can drag files to the app icon in the Dock
//  or to a dedicated drop zone.
//

#if os(macOS)

import AppKit
import Foundation

/// Semi-transparent window that appears when the user
/// drags files over the application.
class DropZoneWindow: NSWindow {

    /// Drop zone that accepts files.
    private let dropView: DropZoneView

    init() {
        dropView = DropZoneView()

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.contentView = dropView
    }

    /// Centers the window on the main screen.
    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowFrame = self.frame
        let newOrigin = NSPoint(
            x: screenFrame.midX - windowFrame.width / 2,
            y: screenFrame.midY - windowFrame.height / 2
        )
        self.setFrameOrigin(newOrigin)
    }
}

/// View that accepts file drag & drop.
class DropZoneView: NSView {

    private var isHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasValidFiles(sender) else { return [] }
        isHighlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isHighlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }

        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return false }

        // Transfer to the main application via URL scheme
        transferToMainApp(urls: fileURLs)
        return true
    }

    // MARK: - Helpers

    private func hasValidFiles(_ info: NSDraggingInfo) -> Bool {
        guard let types = info.draggingPasteboard.types else { return false }
        return types.contains(.fileURL)
    }

    private func transferToMainApp(urls: [URL]) {
        let urlStrings = urls.map { $0.absoluteString }
        let joined = urlStrings.joined(separator: "|")
        guard let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let appURL = URL(string: "airbridge://receive?files=\(encoded)") else {
            return
        }

        NSWorkspace.shared.open(appURL)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.3) : NSColor.windowBackgroundColor.withAlphaComponent(0.9)
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16)
        path.fill()

        // Draw instruction text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        let text = isHighlighted ? "Relâchez pour envoyer" : "Glissez des fichiers ici"
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }
}

#endif
