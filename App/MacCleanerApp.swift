import SwiftUI
import MacCleanerCore

@main
struct MacCleanerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var settings = SettingsStore()

    // No forced appearance. The handoff was authored dark and only dark, and the app
    // used to pin `darkAqua` to match it. The light variant is now derived from that
    // same design in `Token` rather than being absent, so the system decides which one
    // a person sees and the app follows System Settings like any other Mac app.

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow(model: model, settings: settings)
                .frame(
                    minWidth: 1000, idealWidth: Token.Size.windowWidth,
                    minHeight: 640, idealHeight: Token.Size.windowHeight
                )
        }
        .defaultSize(width: Token.Size.windowWidth, height: Token.Size.windowHeight)

        Settings {
            PreferencesView(
                settings: settings,
                categorySizes: model.categorySizes,
                onRebuildIndex: {
                    MacCleanerCore.BreakdownCache.clear()
                    Task { await model.measureStorage() }
                }
            )
        }
        // Without this AppKit lets the Settings window be dragged wider than any of
        // its content; the design specifies a fixed 660 x 484.
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(volume: model.volume)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // The design's Scan menu, with key equivalents.
            CommandMenu("Scan") {
                Button("Scan for Junk") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
            CommandGroup(after: .appSettings) {
                Button("Grant Full Disk Access") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// Keeps a login launch in the menu bar.
///
/// When loginwindow starts the app, only the status item should appear; the full
/// window is for launches the user performs. The launch Apple event names the
/// reason, so a Finder or Dock launch, which carries no such flag, keeps its window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.launchedAsLoginItem else { return }
        closeMainWindows()
        // SwiftUI can present the restored window just after this notification
        // fires, so sweep once more on the next runloop turn.
        DispatchQueue.main.async { self.closeMainWindows() }
    }

    /// Only windows that can become main: the status item's own window and panels
    /// must survive, or the menu bar item dies with the launch.
    private func closeMainWindows() {
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            window.close()
        }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }
}
