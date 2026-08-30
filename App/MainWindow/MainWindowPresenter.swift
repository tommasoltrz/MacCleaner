import AppKit
import SwiftUI

/// Opens the single main window or moves its existing instance to the front.
@MainActor
enum MainWindowPresenter {
    private static var activationRequested = false

    static func present(openWindow: () -> Void) {
        activationRequested = true
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)

        if let window = mainWindow {
            focusRepeatedly(window)
            return
        }

        openWindow()
        DispatchQueue.main.async {
            guard let window = mainWindow else { return }
            focusRepeatedly(window)
        }
    }

    /// Activates a normal Finder, Dock, or Xcode launch after SwiftUI creates its window.
    static func activateAfterLaunch() {
        activationRequested = true
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindow {
            focusRepeatedly(window)
        }
    }

    static func windowDidAttach(_ window: NSWindow) {
        guard activationRequested else { return }
        focusRepeatedly(window)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier == MainWindowIdentityView.identifier }
    }

    private static func focusRepeatedly(_ window: NSWindow) {
        focus(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focus(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard window.isVisible || window.isMiniaturized else { return }
            focus(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard window.isVisible || window.isMiniaturized else {
                activationRequested = false
                return
            }
            focus(window)
            activationRequested = false
        }
    }

    private static func focus(_ window: NSWindow) {
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

struct MainWindowIdentityView: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("Scolo.mainWindow")

    func makeNSView(context: Context) -> NSView {
        IdentityView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class IdentityView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.identifier = MainWindowIdentityView.identifier
            MainWindowPresenter.windowDidAttach(window)
        }
    }
}
