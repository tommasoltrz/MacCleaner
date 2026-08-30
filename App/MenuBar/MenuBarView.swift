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
        // Two paddings, not one. The rows are inset 6 pt so their highlight runs
        // close to the popover's edges the way a menu's does, and everything that
        // is not a row is inset a further 6 pt so its text still lines up with the
        // row labels at 12 pt from the edge.
        VStack(alignment: .leading, spacing: 6) {
            Group {
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
            }
            .padding(.horizontal, 6)

            Button("Scan for Junk") {
                NSApp.activate(ignoringOtherApps: true)
                model.startScan()
            }
            .disabled(model.isScanning)

            Button("Open Scolo") {
                // Hide the menu window before the main window requests key status.
                NSApp.keyWindow?.orderOut(nil)
                // Wait until AppKit finishes the menu click and releases key status.
                DispatchQueue.main.async {
                    MainWindowPresenter.present {
                        openWindow(id: "main")
                    }
                }
            }

            Divider()
                .padding(.horizontal, 6)

            Button("Quit Scolo") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(MenuItemButtonStyle())
        .padding(6)
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
