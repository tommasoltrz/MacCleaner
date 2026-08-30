import SwiftUI
import ScoloCore

/// The menu bar item: a live free-space readout and a one-click purge, as the
/// design's Preferences › General describes it.
///
/// It reads the cached breakdown rather than measuring. A menu bar item that walked
/// the disk whenever the menu opened would be a background process quietly hammering
/// the filesystem — and on an unsigned build, re-triggering permission prompts.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormatting.string(volume.freeBytes)) free")
                        .font(.mcRowTitle)
                    Text("of \(ByteFormatting.string(volume.capacityBytes)) on \(volume.name)")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                }

                ProgressView(
                    value: Double(volume.usedBytes),
                    total: Double(max(volume.capacityBytes, 1))
                )
                .progressViewStyle(.linear)
            } else {
                Text("Measuring…")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
            }

            Divider()

            Button("Scan for Junk") {
                NSApp.activate(ignoringOtherApps: true)
                model.startScan()
            }
            .disabled(model.isScanning)

            Button("Open Scolo") {
                // Promote before the window exists so it opens already in the Dock
                // and takes focus on the first try; the delegate would otherwise do
                // it a beat later, after the window has become main.
                AppDelegate.setPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider()

            Button("Quit Scolo") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 240)
    }
}

/// The label shown in the menu bar itself.
struct MenuBarLabel: View {
    let volume: VolumeInfo?

    var body: some View {
        // Icon only: the menu bar is crowded real estate, and the figure is one
        // click away inside the menu. The asset is the app mark as a vector with
        // its own 6 pt of padding baked in, tagged `template-rendering-intent`
        // so the menu bar tints it — black on light, white on dark, inverted
        // while the popover is open. 18 pt total puts the 15 pt glyph at the
        // same optical weight as the SF Symbol it replaces.
        Image(.menuBarIcon)
            .renderingMode(.template)
    }
}
