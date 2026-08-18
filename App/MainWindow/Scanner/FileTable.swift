import SwiftUI
import AppKit
import MacCleanerCore

/// The expanded body of a Scanner category: a recessed well holding a column header
/// and one row per removable thing.
///
/// Deliberately not `Table`. The design's row is a two-line name cell, a checkbox that
/// is the only selection affordance, and an action button that stays dim until the
/// pointer arrives — none of which the stock table gives without being fought. What
/// `Table` would have contributed for free, column alignment, is a fixed-width frame
/// here and costs three constants.
struct FileTable: View {
    let entries: [FileEntry]
    @Binding var selection: Set<FileEntry.ID>

    /// Anchor for shift-click: the row whose checkbox was clicked last, `nil` until
    /// the first click. Indices into `entries`, so it is the visible row order the
    /// range spans — which is what the user is looking at.
    @State private var lastClickedIndex: Int?

    /// Rows disclosed to show their associated files (an app's leftovers).
    @State private var expandedRows: Set<FileEntry.ID> = []

    enum SortKey { case name, lastOpened, size }
    @State private var sortKey: SortKey = .size
    @State private var ascending = false

    /// The rows as displayed. Shift-click ranges span this order, not the scanner's,
    /// because a range selection over an order the user cannot see selects files
    /// they did not point at.
    private var sortedEntries: [FileEntry] {
        switch sortKey {
        case .name:
            entries.sorted {
                let result = $0.displayName.localizedStandardCompare($1.displayName)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .lastOpened:
            entries.sorted {
                let lhs = $0.lastOpened ?? .distantPast
                let rhs = $1.lastOpened ?? .distantPast
                return ascending ? lhs < rhs : lhs > rhs
            }
        case .size:
            entries.sorted {
                ascending ? $0.allocatedBytes < $1.allocatedBytes
                          : $0.allocatedBytes > $1.allocatedBytes
            }
        }
    }

    /// Adopting a column starts from its natural direction — names read A→Z, dates
    /// oldest-first (the removal candidates), sizes largest-first. A second click
    /// flips. The shift-click anchor resets because it indexes the visible order.
    private func adopt(_ key: SortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = (key != .size)
        }
        lastClickedIndex = nil
    }

    var body: some View {
        // Radius 0: this sits flush inside the category box, edge to edge, with the
        // next category's row directly beneath it. Rounding the corners would float
        // it off a surface it is meant to be recessed into.
        Well(radius: 0) {
            VStack(spacing: 0) {
                columnHeader
                Hairline()
                rows
            }
        }
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(spacing: Metrics.gap) {
            SortableColumnHeader(
                title: "Name",
                isActive: sortKey == .name,
                ascending: ascending,
                action: { adopt(.name) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            SortableColumnHeader(
                title: "Last opened",
                isActive: sortKey == .lastOpened,
                ascending: ascending,
                action: { adopt(.lastOpened) }
            )
            .frame(width: Metrics.lastOpened, alignment: .leading)
            // The honest caveat, one hover away. Spotlight's real last-used date is
            // null for almost everything on this macOS, so most rows fall back to a
            // modification date — and a folder's own date only changes when its
            // direct children do, not its contents.
            .help("Spotlight's last-opened date when it exists; otherwise the last "
                  + "modification date. Treat it as an approximation, not a promise.")

            SortableColumnHeader(
                title: "Size",
                isActive: sortKey == .size,
                ascending: ascending,
                action: { adopt(.size) }
            )
            .frame(width: Metrics.size, alignment: .trailing)
            // Empty slot over the reveal buttons, so SIZE lands above the figures
            // rather than above the icons.
            Color.clear.frame(width: Metrics.action, height: 0)
        }
        .font(.mcColumnHeader)
        .tracking(0.04 * 10.5)
        .textCase(.uppercase)
        .foregroundStyle(Token.Text.quaternary)
        .padding(.leading, Metrics.headerInset)
        .padding(.trailing, Metrics.sidePadding)
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    /// Lazy because a category can expand into hundreds of entries, and every one of
    /// them carries a live checkbox and a hover tracker.
    private var rows: some View {
        let visible = sortedEntries
        return LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Hairline() }
                FileRow(
                    entry: entry,
                    isSelected: selection.contains(entry.id),
                    isExpanded: expandedRows.contains(entry.id),
                    onToggle: { isOn in setSelected(isOn, at: index) },
                    onDisclose: { toggleDisclosure(entry.id) }
                )
                // An entry with associated files (an app and its leftovers)
                // discloses into them. Children select individually — a cache can go
                // while the app stays — but a selected parent implies all of them,
                // because the reverse (keeping a leftover whose app is removed)
                // is not a choice the remover honours.
                if expandedRows.contains(entry.id) {
                    ForEach(entry.children) { child in
                        Hairline()
                        ChildRow(
                            entry: child,
                            // A selected parent implies every child: the app and its
                            // leftovers go together, so the child shows as checked
                            // and locked rather than offering a choice that would
                            // not be honoured.
                            isSelected: selection.contains(child.id) || selection.contains(entry.id),
                            isImpliedByParent: selection.contains(entry.id),
                            onToggle: { isOn in
                                if isOn { selection.insert(child.id) }
                                else { selection.remove(child.id) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func toggleDisclosure(_ id: FileEntry.ID) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expandedRows.contains(id) { expandedRows.remove(id) }
            else { expandedRows.insert(id) }
        }
    }

    // MARK: - Selection

    /// Applies a checkbox click, extending it over a range when Shift is held.
    ///
    /// The modifier is read from `NSEvent` rather than tracked in state because a
    /// `Toggle` reports its new value, not the event that produced it — and a real
    /// checkbox is worth more than a hand-drawn one that could carry the flags. The
    /// clicked checkbox's new state is the one painted across the span, so a
    /// shift-click that unchecks clears the range; the anchor then moves to the row
    /// just clicked, which is how checkbox lists behave.
    private func setSelected(_ isOn: Bool, at index: Int) {
        // Indices are into the *sorted* order — the rows the user is looking at.
        let visible = sortedEntries
        var affected = [index]
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = lastClickedIndex,
           visible.indices.contains(anchor) {
            affected = Array(min(anchor, index)...max(anchor, index))
        }

        for position in affected {
            let entry = visible[position]
            // A shift-range sweeping over a locked row leaves it untouched — the
            // locked checkbox must not be reachable through a side door.
            guard !entry.isRemovalLocked else { continue }
            if isOn {
                selection.insert(entry.id)
                // The parent's selection now covers its children; individual child
                // selections would double-count the same bytes.
                for child in entry.children { selection.remove(child.id) }
            } else {
                selection.remove(entry.id)
            }
        }
        lastClickedIndex = index
    }
}

// MARK: - One row

private struct FileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    var isExpanded = false
    let onToggle: (Bool) -> Void
    var onDisclose: (() -> Void)?

    @State private var isRowHovered = false
    @State private var isShowingManualInfo = false

    var body: some View {
        HStack(spacing: Metrics.gap) {
            // The slot the category row's triangle occupies, so file names stay
            // aligned under the category title. It holds a disclosure of its own
            // when the entry has associated files to show.
            Group {
                if !entry.children.isEmpty, let onDisclose {
                    Button(action: onDisclose) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Token.Text.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.children.count) associated files, removed with the app")
                } else {
                    Color.clear
                }
            }
            .frame(width: Metrics.disclosureSlot)

            // The label is hidden but not dropped — it is what VoiceOver reads.
            Toggle(entry.displayName, isOn: Binding(get: { isSelected }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.isRemovalLocked)
                .help(parentHelp)
                .frame(width: Metrics.checkbox)

            // An app bundle shows its real icon — the `app` SF symbol is an empty
            // rounded square that reads as a second, broken checkbox next to the
            // real one.
            Group {
                if entry.kind == .appBundle {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: entry.kind.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(Token.color(entry.kind.color))
                }
            }
            .frame(width: Metrics.icon)

            nameBlock

            Text(lastOpenedText)
                .font(.mcRowValue)
                .foregroundStyle(entry.lastOpened == nil
                    ? Token.textColor(.orange) : Token.Text.secondary)
                .lineLimit(1)
                .frame(width: Metrics.lastOpened, alignment: .leading)

            // `fixedSize` before the frame: the column is wide enough for every value
            // the formatter produces, and a truncated size would be a lie rather than
            // an abbreviation.
            Text(ByteFormatting.string(entry.allocatedBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Metrics.size, alignment: .trailing)

            RevealButton(url: entry.url, name: entry.displayName, isRowHovered: isRowHovered)
        }
        .padding(.horizontal, Metrics.sidePadding)
        .frame(height: Token.Size.fileRow)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onHover { isRowHovered = $0 }
        // The whole row is a target, not just its smallest control: a row that can
        // disclose discloses, and a plain row toggles its checkbox. The checkbox and
        // reveal button keep their own clicks — SwiftUI gives embedded controls
        // precedence over the row's gesture.
        .onTapGesture {
            if !entry.children.isEmpty, let onDisclose {
                onDisclose()
            } else if entry.manualRemoval != nil {
                isShowingManualInfo = true
            } else if !entry.isRemovalLocked {
                onToggle(!isSelected)
            }
        }
    }

    private var parentHelp: String {
        if entry.manualRemoval != nil {
            return "This app cannot delete this item. Click the terminal badge for "
                + "the command that does."
        }
        switch entry.protectionReason {
        case .running:
            return "This app is running. Quit it to remove it. Its support files "
                + "below can still be removed individually."
        case .recentUse:
            // Information, not a lock: the checkbox works.
            return "Used inside your protection window (Preferences › Exclusions). "
                + "You can still remove it."
        case .userData:
            return "Contains user data. It is removed only with the whole app."
        case nil:
            return ""
        }
    }

    private static func badgeText(for reason: FileEntry.ProtectionReason) -> String {
        switch reason {
        case .running:   "running"
        case .recentUse: "recently used"
        case .userData:  "user data"
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Middle truncation on both lines: the tail of a filename carries the
            // extension and the tail of a path carries the folder you recognise.
            HStack(spacing: 6) {
                Text(entry.displayName)
                    .font(.mcBody)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let manual = entry.manualRemoval {
                    // A badge that answers itself: click for the explanation and the
                    // command, with the command one click from the clipboard.
                    Button { isShowingManualInfo = true } label: {
                        Badge(text: "terminal").fixedSize()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingManualInfo, arrowEdge: .bottom) {
                        ManualRemovalPopover(manual: manual)
                    }
                } else if let reason = entry.protectionReason {
                    // Says *why* the checkbox is locked without hovering anything,
                    // and says the true thing: "in use" on an app that was merely
                    // opened last week reads as a lie.
                    Badge(text: Self.badgeText(for: reason)).fixedSize()
                }
            }

            // `parentQualifier`, not `parentDisplay` — the `· 1,204 items` and
            // `· regenerable` suffixes are most of what makes this line worth reading.
            Text(entry.parentQualifier)
                .font(.mcMonoSmall)
                .foregroundStyle(Token.Text.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `nil` is genuinely rare — the scanner falls back through several date sources
    /// before giving up — so when it does appear it means nobody has ever opened this,
    /// and the design makes it the one coloured thing in the row.
    @MainActor
    private var lastOpenedText: String {
        guard let lastOpened = entry.lastOpened else { return "Never opened" }
        // Inside a minute the formatter says "in 0 seconds", which reads as a bug.
        guard Date.now.timeIntervalSince(lastOpened) >= 60 else { return "Just now" }
        return lastOpenedFormatter.localizedString(for: lastOpened, relativeTo: .now)
    }
}

// MARK: - Reveal in Finder

/// The row's only action. It does not delete, rename or preview: it hands the file to
/// Finder and lets the user decide there, which is the honest thing for a row whose
/// checkbox is otherwise a vote to throw something away.
/// An associated file under a disclosed parent — an app's cache, container, or
/// preference file. Informational only: it is removed with the parent, so it has no
/// checkbox and no reveal button, just enough to answer "what exactly comes along?".
private struct ChildRow: View {
    let entry: FileEntry
    let isSelected: Bool
    /// True when the parent app is selected, which already covers this file.
    let isImpliedByParent: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Metrics.gap) {
            // Indented one slot past the parent, so the hierarchy reads without a
            // tree line.
            Color.clear.frame(width: Metrics.disclosureSlot, height: 0)

            Toggle(entry.displayName, isOn: Binding(get: { isSelected }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .disabled(isImpliedByParent || entry.isRemovalLocked)
                .help(childHelp)
                .frame(width: Metrics.checkbox)

            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(Token.Text.quaternary)
                .frame(width: Metrics.icon)

            Text(FileEntry.abbreviate(entry.url.path))
                .font(.mcMonoSmall)
                .foregroundStyle(Token.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.url.path)

            Text(ByteFormatting.string(entry.allocatedBytes))
                .font(.mcMonoSmall)
                .foregroundStyle(Token.Text.tertiary)
                .fixedSize()
                .frame(width: Metrics.size, alignment: .trailing)

            Color.clear.frame(width: Metrics.action, height: 0)
        }
        .padding(.horizontal, Metrics.sidePadding)
        .frame(height: 28)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture {
            if !isImpliedByParent, !entry.isRemovalLocked { onToggle(!isSelected) }
        }
    }

    private var childHelp: String {
        if isImpliedByParent {
            return "Removed with the app. Deselect the app to choose individually."
        }
        if entry.protectionReason == .userData {
            return "Protected: logins, history and settings live here. Remove the "
                + "whole app to remove this."
        }
        if entry.isRemovalLocked {
            return "Protected while the app is running."
        }
        return "Remove just this file, keeping the app"
    }
}


/// The explanation and the command for an entry only a tool can remove.
private struct ManualRemovalPopover: View {
    let manual: FileEntry.ManualRemoval
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(manual.explanation)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Text(manual.command)
                    .font(.mcMonoPath)
                    .foregroundStyle(Token.Text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manual.command, forType: .string)
                    didCopy = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

private struct RevealButton: View {
    let url: URL
    let name: String
    let isRowHovered: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11.5))
                .foregroundStyle(glyphColor)
                .frame(width: Metrics.action, height: Metrics.action)
                .background(
                    isHovered ? Token.Fill.control : .clear,
                    in: RoundedRectangle(cornerRadius: Token.Radius.checkbox)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Reveal in Finder")
        .accessibilityLabel("Reveal \(name) in Finder")
    }

    /// Dim at rest — lit on every row at once, a column of these would read as data
    /// rather than as something to press.
    private var glyphColor: Color {
        if isHovered { return Token.Text.primary }
        return isRowHovered ? Token.Text.secondary : Token.Text.disabled
    }
}

// MARK: - Shared parts

private enum Metrics {
    static let sidePadding: CGFloat = 15
    static let gap: CGFloat = 11
    static let disclosureSlot: CGFloat = 11
    static let checkbox: CGFloat = 15
    static let icon: CGFloat = 15
    /// Fixed, so the dates and sizes line up down the column while the name flexes
    /// with the window.
    static let lastOpened: CGFloat = 104
    static let size: CGFloat = 82
    static let action: CGFloat = 22

    /// The header starts at the checkbox's trailing edge: 15 + 11 + 11 + 15.
    static var headerInset: CGFloat { sidePadding + disclosureSlot + gap + checkbox }
}

/// One physical pixel. `NSColor.separatorColor` is several times stronger than the
/// design's row rule; repeated every 38pt it draws a grid rather than a hint, so this
/// uses the box hairline, which is the token that matches the intended weight.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }
}

/// One formatter, not one per row: building these is expensive and a long category
/// renders hundreds.
@MainActor private let lastOpenedFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named   // "yesterday" over "1 day ago"
    return formatter
}()

// MARK: - Preview

#Preview("Expanded category body") {
    @Previewable @State var selection: Set<FileEntry.ID> = [PreviewEntries.designArchive.id]

    FileTable(entries: PreviewEntries.all, selection: $selection)
        .background(Token.Fill.box)
        .padding(24)
        .frame(width: 940)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

/// The design's own sample rows for Documents & Files.
private enum PreviewEntries {
    private static let gigabyte = Double(ByteFormatting.bytesPerGB)
    private static func daysAgo(_ days: Double) -> Date {
        Date.now.addingTimeInterval(-days * 86_400)
    }
    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * gigabyte) }
    private static func home(_ path: String) -> URL {
        URL(filePath: NSHomeDirectory()).appending(path: path)
    }

    /// Never opened, and therefore the one orange thing on screen.
    static let archive = FileEntry(
        url: home("Downloads/Xcode_16.2.xip"),
        kind: .archive,
        allocatedBytes: gigabytes(8.42)
    )

    static let folder = FileEntry(
        url: home("Movies/Screen Recordings"),
        kind: .folder,
        allocatedBytes: gigabytes(6.18),
        lastOpened: daysAgo(120),
        childCount: 62
    )

    /// Selected on load, to show the checked state against the others.
    static let designArchive = FileEntry(
        url: home("Documents/Design Archive 2024"),
        kind: .folder,
        allocatedBytes: gigabytes(4.31),
        lastOpened: daysAgo(243),
        childCount: 1_204
    )

    static let cache = FileEntry(
        url: home("Pictures/Lightroom Previews.lrdata"),
        kind: .cache,
        allocatedBytes: gigabytes(1.84),
        lastOpened: daysAgo(61),
        isRegenerable: true
    )

    /// A name long enough to exercise middle truncation.
    static let longName = FileEntry(
        url: home("Downloads/node_modules-backup-2024-final-really-final-v3.zip"),
        kind: .file,
        allocatedBytes: gigabytes(2.07),
        lastOpened: daysAgo(365)
    )

    static let all = [archive, folder, designArchive, longName, cache]
}
