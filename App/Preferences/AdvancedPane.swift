import AppKit
import SwiftUI
import ScoloCore

/// Preferences → Advanced: how removal behaves, the diagnostics, and the reset.
struct AdvancedPane: View {

    @Bindable var settings: SettingsStore

    /// Rebuilding walks the disk, so the work belongs to whoever owns the scan
    /// coordinator. With no handler the button is disabled rather than inert — a
    /// control that looks live and does nothing is worse than one that admits it.
    var onRebuildIndex: (() -> Void)?
    /// Removes the dated measurements the Dashboard subtracts. A different file
    /// from the breakdown cache, and a different button.
    var onClearMeasurementHistory: (() -> Void)?
    /// Called after the store has been reset, for state the store does not own
    /// (selections, cached measurements).
    var onResetSettings: (() -> Void)?

    @State private var isConfirmingReset = false

    private enum Metrics {
        static let resetPaddingH: CGFloat = 14
        static let resetPaddingV: CGFloat = 12
    }

    var body: some View {
        PrefPane {
            removalBehaviour
            diagnostics
            resetRow
        }
        .alert("Reset all settings?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                onResetSettings?()
            }
        } message: {
            // Says what is *not* affected, because "reset" next to a disk cleaner reads
            // as something that touches files.
            Text("Categories, exclusions and schedules return to their defaults. Nothing on disk is removed.")
        }
    }

    // MARK: - Removal behaviour

    private var removalBehaviour: some View {
        PrefSection("Removal behaviour") {
            PrefToggleRow(
                title: "Always move to Trash, never delete",
                description: "Off means caches are unlinked immediately. This is faster and unrecoverable.",
                isOn: $settings.trashFirst
            )
            PrefDivider()
            PrefToggleRow(
                title: "Confirm before every clean-up",
                isOn: $settings.confirmBeforeCleanup
            )
            // "Follow symlinks while measuring" used to live here. It was removed
            // rather than repaired: following a link counts its target a second
            // time, under a name that does not own those bytes. That breaks the
            // capacity card's one contract — every byte of the disk accounted for
            // exactly once — and with it on, a 228 GB disk measured 274 GB, the
            // Unmeasured residual floored to zero and the bar ran off the card.
            // Scans must not follow links either (removing a link frees the link,
            // not its target), so the option had no correct consumer left. The
            // measurer still supports it as a primitive for anything that one day
            // genuinely wants "how big is this tree, links included".
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        PrefSection("Diagnostics") {
            PrefRow(
                title: "Keep a removal log",
                description: RemovalLog.displayPath,
                descriptionIsPath: true
            ) {
                Button("Reveal in Finder") { RemovalLog.reveal() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            PrefDivider()
            PrefRow(
                title: "Rebuild the size index",
                // The design's "Last built 16 Aug at 9:41 AM · 1.2M paths" needs a
                // timestamp nothing records yet; this says what the button does
                // instead of inventing the line.
                description: "Discards the cached measurements and measures every folder again."
            ) {
                Button("Rebuild") { onRebuildIndex?() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(onRebuildIndex == nil)
            }
            PrefDivider()
            PrefRow(
                title: "Clear measurement history",
                // Says what goes and what the cost is. The Dashboard's growth card
                // has nothing to subtract until two measurements exist again.
                description: "Removes the stored measurements that the Dashboard "
                    + "compares. The next two measurements start a new history."
            ) {
                Button("Clear") { onClearMeasurementHistory?() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(onClearMeasurementHistory == nil)
            }
        }
    }

    // MARK: - Reset

    /// Standalone and red: it belongs to no section because it undoes all of them.
    private var resetRow: some View {
        HStack(spacing: PrefMetrics.controlGap) {
            PrefLabel(
                title: "Reset all settings",
                description: "Categories, exclusions and schedules return to defaults."
            )

            Spacer(minLength: PrefMetrics.controlGap)

            Button("Reset") { isConfirmingReset = true }
                .buttonStyle(DestructiveButtonStyle())
        }
        .padding(.horizontal, Metrics.resetPaddingH)
        .padding(.vertical, Metrics.resetPaddingV)
        .background(
            Token.color(.red).opacity(0.09),
            in: RoundedRectangle(cornerRadius: Token.Radius.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(Token.color(.red).opacity(0.30), lineWidth: Token.hairline)
        )
    }
}

// MARK: - Removal log

/// Where the removal log lives, and how to show it.
enum RemovalLog {

    static var url: URL {
        URL.libraryDirectory.appending(path: "Logs/Scolo/removals.log")
    }

    /// Tilde-abbreviated, as the design prints it.
    static var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// Selects the log in Finder, or the deepest folder on its way there.
    ///
    /// Nothing creates the file until the first removal, and
    /// `activateFileViewerSelecting` on a path that does not exist does nothing at all
    /// — a button that appears dead until the app has deleted something once.
    @MainActor
    static func reveal() {
        let fileManager = FileManager.default
        var target = url
        while !fileManager.fileExists(atPath: target.path(percentEncoded: false)),
              target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Preview

#Preview("Advanced") {
    AdvancedPane(
        settings: .preview(),
        onRebuildIndex: {},
        onClearMeasurementHistory: {},
        onResetSettings: {}
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
