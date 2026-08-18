import SwiftUI
import MacCleanerCore

@main
struct MacCleanerApp: App {

    @State private var model = AppModel()
    @State private var settings = SettingsStore()

    // The design specifies a single dark appearance — there is no light variant in
    // the handoff, and the token set is macOS dark-mode system colours throughout.
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

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
