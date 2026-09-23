import AppKit

extension NSOpenPanel {
    /// Presents the panel over the app's own main window, the way every other
    /// confirmation in the app is presented.
    ///
    /// The window has to be found by identity. `NSApp.mainWindow ?? NSApp.keyWindow`
    /// answers with whatever is in front at that instant, and this app puts other
    /// things there: the menu bar extra's panel, the Settings window, a Quick Look
    /// preview. A sheet begun on a window that cannot show one — or on a window that
    /// already has one, where AppKit silently queues it behind the first — appears
    /// nowhere, the `await` never returns, and the button reads as dead. That is
    /// exactly what "Choose Folder…" and "Choose Folders" did.
    ///
    /// When there is no window to attach to, the panel is shown on its own with
    /// `begin`, never `runModal()`: a nested modal loop started from inside a task
    /// stops the main actor from running anything else, including whatever would
    /// dismiss the panel.
    @MainActor
    func presentAsSheet() async -> NSApplication.ModalResponse {
        guard let window = Self.sheetHost else { return await present() }
        return await beginSheetModal(for: window)
    }

    /// The one window a sheet belongs on: the main window, visible, with nothing
    /// already attached to it.
    private static var sheetHost: NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil
        }
        return candidates.first { $0.identifier == MainWindowIdentity.identifier }
            ?? candidates.first { $0.isMainWindow }
            ?? candidates.first { $0.isKeyWindow }
    }

    /// The panel on its own, and the caller still gets to await the answer.
    private func present() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}
