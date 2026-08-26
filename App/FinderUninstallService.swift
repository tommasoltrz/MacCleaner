import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives one application from the Finder Services menu.
@MainActor
final class FinderUninstallServiceProvider: NSObject {
    @objc(reviewUninstall:userData:error:)
    func reviewUninstall(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.applicationBundle.identifier],
        ]
        let urls = pasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { ($0 as? NSURL)?.absoluteURL } ?? []

        guard urls.count == 1, let applicationURL = urls.first else {
            error.pointee = "Select one application in Finder, then try again."
            return
        }
        guard applicationURL.isFileURL,
              applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        else {
            error.pointee = "Finder did not provide a valid application."
            return
        }

        FinderUninstallRequestCenter.shared.submit(applicationURL)
    }
}

/// Keeps one Finder request until the main window can receive it.
@MainActor
final class FinderUninstallRequestCenter {
    static let shared = FinderUninstallRequestCenter()

    private var handler: ((URL) -> Void)?
    private var presenter: (() -> Void)?
    private var pendingURL: URL?

    private init() {}

    func install(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        guard let pendingURL else { return }
        self.pendingURL = nil
        handler(pendingURL)
    }

    func installPresenter(_ presenter: @escaping () -> Void) {
        self.presenter = presenter
    }

    func submit(_ applicationURL: URL) {
        let applicationURL = applicationURL.standardizedFileURL
        presenter?()
        guard let handler else {
            pendingURL = applicationURL
            return
        }
        handler(applicationURL)
    }
}

/// Connects Finder requests to the existing uninstall review.
struct FinderUninstallRequestReceiver: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowIdentityView()
            .frame(width: 0, height: 0)
            .onAppear {
                FinderUninstallRequestCenter.shared.installPresenter {
                    presentMainWindow()
                }
            }
    }

    private func presentMainWindow() {
        AppDelegate.setPolicy(.regular)
        NSApp.unhide(nil)

        if let window = NSApp.windows.first(where: {
            $0.identifier == MainWindowIdentityView.identifier
        }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MainWindowIdentityView: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("MacCleaner.mainWindow")

    func makeNSView(context: Context) -> NSView {
        IdentityView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class IdentityView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MainWindowIdentityView.identifier
        }
    }
}
