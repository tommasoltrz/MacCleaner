import SwiftUI
import AppKit
import MacCleanerCore

/// The Dashboard's APFS Snapshots row.
///
/// It exists to answer one support question: "why does the app say 0 removable
/// snapshots when I can see a snapshot?" Since Big Sur, macOS boots from a sealed,
/// read-only APFS snapshot of the System volume named `com.apple.os.update-<hash>`.
/// The prefix reads like update leftovers, so people try to delete it — from Recovery
/// Mode, with SIP disabled — and cannot, because it *is* the running operating system.
///
/// So the row names it, explains it, and offers no way to act on it. There is
/// deliberately no delete affordance and no "how to remove it" hint anywhere below:
/// the only honest thing to do with the boot snapshot is describe it.
struct SnapshotsDisclosureRow: View {

    /// Everything the row needs from a snapshot.
    ///
    /// `SnapshotInfo`'s memberwise initialiser is internal to MacCleanerCore, so this
    /// target cannot build one. Deriving a local value lets the preview exercise both
    /// states without widening Core's API from here.
    fileprivate struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private let removable: [Entry]
    private let bootSnapshotName: String?
    @Binding private var isExpanded: Bool

    @State private var isShowingHelp = false

    init(snapshots: [SnapshotInfo], isExpanded: Binding<Bool>) {
        self.removable = snapshots
            .filter { !$0.isBootSnapshot }
            .map { Entry(id: $0.uuid, name: $0.name) }
        self.bootSnapshotName = snapshots.first(where: \.isBootSnapshot)?.name
        self._isExpanded = isExpanded
    }

    fileprivate init(removable: [Entry], bootSnapshotName: String?, isExpanded: Binding<Bool>) {
        self.removable = removable
        self.bootSnapshotName = bootSnapshotName
        self._isExpanded = isExpanded
    }

    private enum Metrics {
        static let sidePadding: CGFloat = 16
        /// Fixed slot so the title does not shift when the triangle rotates.
        static let triangleSlot: CGFloat = 11
        static let triangleGap: CGFloat = 10
        /// The body aligns under the title, not under the triangle.
        static var bodyIndent: CGFloat { sidePadding + triangleSlot + triangleGap }
    }

    var body: some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded { expandedBody }
            }
            // Clipped inside the box so the header's hover fill and the expanding
            // body both stop at the rounded corners, under the border.
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
        }
    }

    // MARK: - Header

    // A plain header button rather than `DisclosureGroup`: the design needs the whole
    // row — triangle included — to be one hit target with a hover fill spanning the
    // full width, and needs the body indented to the title. `DisclosureGroup` draws
    // the triangle outside its label, so no label content can cover it or paint behind
    // it, and it applies its own content indent. Fighting both leaves less native
    // behaviour than reproducing the two things it actually gives us: a rotating
    // triangle and the platform's default animation.
    private var header: some View {
        Button {
            // SwiftUI's default curve runs ~0.35s, which drags for a disclosure the
            // user is toggling in order to read something. The design's whole
            // animation inventory tops out at 260ms and asks for restraint.
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Metrics.triangleGap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Token.Text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Metrics.triangleSlot, alignment: .leading)

                Text("APFS Snapshots")
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)

                Badge(text: "\(removable.count) removable")

                Spacer(minLength: 12)

                Text(statusLine)
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Metrics.sidePadding)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private var statusLine: String {
        switch removable.count {
        case 0:      "Time Machine holds no local snapshots"
        case 1:      "Time Machine holds 1 local snapshot"
        case let n:  "Time Machine holds \(n) local snapshots"
        }
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        Well {
            VStack(alignment: .leading, spacing: 9) {
                if !removable.isEmpty { removableList }
                bootExplanation
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Metrics.bodyIndent)
        .padding(.trailing, Metrics.sidePadding)
        .padding(.bottom, 15)
    }

    /// Time Machine's local snapshots — the only snapshots on the machine that a
    /// person can actually get rid of. Listed, but not acted on from the Dashboard.
    private var removableList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Time Machine local snapshots. These are real, deletable copies of your data.")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(removable) { snapshot in
                HStack(spacing: 7) {
                    CategoryDot(color: .green, size: 5)
                    Text(snapshot.name)
                        .font(.mcMonoSmall)
                        .foregroundStyle(Token.Text.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.top, 2)
        }
    }

    @ViewBuilder
    private var bootExplanation: some View {
        if let bootSnapshotName {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Boot snapshot. This is macOS itself, not reclaimable space.")
                        .font(.mcControlLabel)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HelpButton { isShowingHelp.toggle() }
                        .popover(isPresented: $isShowingHelp) { helpExplanation }

                    Spacer(minLength: 0)
                }

                // One unbroken 80-character token. `fixedSize` vertically only means
                // the width still comes from the parent, so the string breaks
                // mid-token across lines instead of truncating or widening the window.
                Text(bootSnapshotName)
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("No boot snapshot was reported for this volume.")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
        }
    }

    private var helpExplanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Why this one cannot be removed")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)

            Text("Since macOS Big Sur, your Mac boots from a sealed, read-only APFS "
                 + "snapshot of the System volume, mounted at /. The "
                 + "com.apple.os.update- prefix makes it look like a leftover from a "
                 + "software update. It is not: it is the copy of macOS running right "
                 + "now.")

            Text("It cannot be deleted from Recovery Mode, and disabling System "
                 + "Integrity Protection does not change that. Reinstalling macOS "
                 + "simply creates a new one.")

            Text("Removing it would free nothing, so it is never counted as removable.")
        }
        .font(.mcSubtitle)
        .foregroundStyle(Token.Text.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Help button

/// SwiftUI has no help-button style on macOS 26, so this is the AppKit control itself
/// — the round `?` from every system dialog. A hand-drawn circle would read as a
/// mystery glyph sitting next to native chrome.
private struct HelpButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .helpButton
        button.title = ""
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setAccessibilityLabel("About the boot snapshot")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func fire() { action() }
    }
}

// MARK: - Preview

#Preview("APFS Snapshots") {
    @Previewable @State var bootOnlyExpanded = true
    @Previewable @State var withTimeMachineExpanded = true

    let bootName = "com.apple.os.update-"
        + "60587424F5399FC05D957DF05B4D2F65543462495C77AEF520F790FBB57CB212"

    VStack(spacing: 16) {
        // The common case: one snapshot exists, none of it is yours to delete.
        SnapshotsDisclosureRow(
            removable: [],
            bootSnapshotName: bootName,
            isExpanded: $bootOnlyExpanded
        )

        SnapshotsDisclosureRow(
            removable: [
                .init(id: "1E0B", name: "com.apple.TimeMachine.2026-08-17-131500.local"),
                .init(id: "7C4A", name: "com.apple.TimeMachine.2026-08-16-094100.local")
            ],
            bootSnapshotName: bootName,
            isExpanded: $withTimeMachineExpanded
        )
    }
    .padding(24)
    .frame(width: 940)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
