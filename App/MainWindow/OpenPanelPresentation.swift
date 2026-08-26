import AppKit

extension NSOpenPanel {
    /// Presents the panel as a sheet on the main window, the way every other
    /// confirmation in the app is presented. `runModal()` floated a detached panel
    /// over whatever was in front and stalled the run loop while it was up. The
    /// modal form remains for the one case with no window to attach to.
    @MainActor
    func presentAsSheet() async -> NSApplication.ModalResponse {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return runModal() }
        return await beginSheetModal(for: window)
    }
}
