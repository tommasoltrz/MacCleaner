import SwiftUI
import MacCleanerCore

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

            Button("Open MacCleaner") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider()

            Button("Quit MacCleaner") { NSApp.terminate(nil) }
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
        // An icon plus the free figure, which is the whole reason to have this.
        HStack(spacing: 4) {
            Image(systemName: "internaldrive")
            if let volume {
                Text(ByteFormatting.string(volume.freeBytes))
                    .monospacedDigit()
            }
        }
    }
}
