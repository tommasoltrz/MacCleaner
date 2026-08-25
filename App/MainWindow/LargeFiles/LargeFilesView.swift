import SwiftUI
import AppKit
import MacCleanerCore

/// Large & Old Files: three filters over what the last scan already measured.
///
/// Deliberately not a second traversal. The scan has walked the disk and paid for the
/// permission prompts that go with it, so this view re-reads those figures rather than
/// asking again — and every row here is also a Scanner row, which is why the checkbox
/// writes into the same shared selection pool.
struct LargeFilesView: View {
    @Bindable var model: AppModel

    /// Shift-click anchor, in *visible* row order. A filter change invalidates it, or
    /// a range would span rows that are no longer on screen.
    @State private var anchorIndex: Int?
    /// Protected user data is never selected by an inert checkbox. The lock opens
    /// this row-specific warning first, matching the Scanner's safety contract.
    @State private var pendingUserDataOverride: FileEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.scanResults == nil {
                    emptyState
                } else {
                    let entries = filteredEntries
                    filterSummary(entries)
                    table(entries)
                }
            }
            // Matches the Dashboard and Scanner: content passes under the toolbar and
            // blurs against it, so there is no manual top inset.
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        .onChange(of: model.largeFilesFilter) { anchorIndex = nil }
        .alert(item: $pendingUserDataOverride) { entry in
            Alert(
                title: Text("Remove \(entry.displayName)?"),
                message: Text(
                    "This folder can contain profiles, logins, history, and settings. "
                    + "Removing it may sign you out or reset the app. Quit the app first. "
                    + "MacCleaner will always move this protected data to the Trash."
                ),
                primaryButton: .destructive(Text("Unlock & Select")) {
                    model.userDataRemovalOverrides.insert(entry.id)
                    model.largeFilesSelection.insert(entry.id)
                    pendingUserDataOverride = nil
                },
                secondaryButton: .cancel { pendingUserDataOverride = nil }
            )
        }
    }

    // MARK: - Filter summary

    @ViewBuilder
    private func filterSummary(_ entries: [FileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary(entries))
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.quaternary)
                .lineLimit(1)
                .truncationMode(.tail)

            if model.largeFilesFilter == .duplicates {
                Text("Same-size candidates. They are grouped by identical allocated size, not compared byte for byte. Check the contents before you remove a copy.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
    }

    private func summary(_ entries: [FileEntry]) -> String {
        let noun = entries.count == 1 ? "item" : "items"
        let bytes = entries.reduce(0) { $0 + $1.allocatedBytes }
        return "\(entries.count) \(noun) · \(ByteFormatting.string(bytes)) · excludes anything in your exclusion list"
    }

    // MARK: - Table

    private func table(_ entries: [FileEntry]) -> some View {
        GroupedBox {
            VStack(spacing: 0) {
                columnHeader
                Hairline()

                if entries.isEmpty {
                    noMatches
                } else {
                    // Lazy because "Over 1 GB" is a narrow filter but the other two are
                    // not: every visible row carries a live checkbox and a hover tracker.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Hairline() }
                            LargeFileRow(
                                entry: entry,
                                isSelected: model.largeFilesSelection.contains(entry.id),
                                hasUserDataOverride: model.userDataRemovalOverrides.contains(entry.id),
                                roundsBottomCorners: index == entries.count - 1,
                                onToggle: { isOn in setSelected(isOn, at: index, in: entries) },
                                onRequestUserDataOverride: { pendingUserDataOverride = entry },
                                onUninstallApplication: entry.kind == .appBundle
                                    ? { model.planAppUninstall(entry.url) }
                                    : nil
                            )
                        }
                    }
                    // The uninstall callout rises above the first row. Keep the row
                    // layer above the column header instead of letting the header
                    // cover the glass card.
                    .zIndex(1)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: Metrics.gap) {
            // Empty slot over the checkboxes, so PATH starts above the paths.
            Color.clear.frame(width: Metrics.selection, height: 0)

            SortableColumnHeader(
                title: "Path",
                isActive: sortKey == .path,
                ascending: ascending,
                action: { adopt(.path) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            SortableColumnHeader(
                title: "Kind",
                isActive: sortKey == .kind,
                ascending: ascending,
                action: { adopt(.kind) }
            )
            .frame(width: Metrics.kind, alignment: .leading)

            SortableColumnHeader(
                title: "Size",
                isActive: sortKey == .size,
                ascending: ascending,
                action: { adopt(.size) }
            )
            .frame(width: Metrics.size, alignment: .trailing)
        }
        .font(.mcColumnHeader)
        .tracking(0.04 * 10.5)
        .textCase(.uppercase)
        .foregroundStyle(Token.Text.quaternary)
        .padding(.horizontal, Metrics.sidePadding)
        .padding(.vertical, 7)
    }

    private var noMatches: some View {
        Text(model.largeFilesFilter.emptyMessage)
            .font(.mcBody)
            .foregroundStyle(Token.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.sidePadding)
            .frame(height: Token.Size.largeFileRow)
    }

    // MARK: - Selection

    /// Applies a checkbox click, extending it over a range when Shift is held — the
    /// same idiom as the Scanner's table, reading the modifier from `NSEvent` because
    /// a `Toggle` reports its new value and not the event that produced it.
    private func setSelected(_ isOn: Bool, at index: Int, in entries: [FileEntry]) {
        var affected = [index]
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = anchorIndex,
           entries.indices.contains(anchor) {
            affected = Array(min(anchor, index)...max(anchor, index))
        }

        for position in affected {
            let entry = entries[position]
            // Application bundles have a complete uninstall review; a Shift range
            // must not sneak them into generic cleanup. Locked user data becomes a
            // normal checkbox only after its exact row has been authorized.
            guard entry.kind != .appBundle else {
                model.largeFilesSelection.remove(entry.id)
                continue
            }
            guard !entry.isRemovalLocked
                    || model.userDataRemovalOverrides.contains(entry.id)
            else { continue }
            if isOn {
                model.largeFilesSelection.insert(entry.id)
            } else {
                model.largeFilesSelection.remove(entry.id)
                model.userDataRemovalOverrides.remove(entry.id)
            }
        }
        anchorIndex = index
    }

    // MARK: - Entries

    /// Every scanned entry, once.
    ///
    /// Categories can name the same path twice — an app bundle is an application and a
    /// large folder — and `FileEntry.id` *is* the path, so the duplicate is the same
    /// row rather than a second thing to remove.
    private var uniqueEntries: [FileEntry] {
        var seen: Set<FileEntry.ID> = []
        return (model.scanResults?.categories.flatMap(\.entries) ?? [])
            .filter { seen.insert($0.id).inserted }
    }

    enum SortKey { case path, kind, size }
    @State private var sortKey: SortKey = .size
    @State private var ascending = false

    /// Adopting a column starts from its natural direction — paths and kinds read
    /// A→Z, sizes largest-first — and a second click flips. The shift-click anchor
    /// resets because it indexes the visible order.
    private func adopt(_ key: SortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = (key != .size)
        }
        anchorIndex = nil
    }

    private var filteredEntries: [FileEntry] {
        let entries = uniqueEntries
        let matching: [FileEntry]

        switch model.largeFilesFilter {
        case .overOneGB:
            matching = entries.filter { $0.allocatedBytes >= ByteFormatting.bytesPerGB }
        case .unopenedSixMonths:
            let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .distantPast
            // No date at all counts as unopened: the scanner falls back through several
            // sources before giving up, so `nil` means nothing ever recorded a use.
            matching = entries.filter { ($0.lastOpened ?? .distantPast) < cutoff }
        case .duplicates:
            matching = Self.sameSizeCandidates(in: entries)
        }

        switch sortKey {
        case .path:
            return matching.sorted {
                let result = $0.url.path.localizedStandardCompare($1.url.path)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .kind:
            return matching.sorted {
                if $0.kind == $1.kind { return $0.allocatedBytes > $1.allocatedBytes }
                let result = $0.kind.rawValue.localizedStandardCompare($1.kind.rawValue)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size:
            return matching.sorted {
                ascending ? $0.allocatedBytes < $1.allocatedBytes
                          : $0.allocatedBytes > $1.allocatedBytes
            }
        }
    }

    /// Files sharing an allocated size with at least one other, above a floor where the
    /// coincidence stops being cheap.
    ///
    /// This compares sizes, not contents. Two exports of one video and two unrelated
    /// files that happen to round to the same allocation are indistinguishable from
    /// here, so the filter's caption calls them candidates and this app never claims
    /// to have found a duplicate it has not read.
    private static func sameSizeCandidates(in entries: [FileEntry]) -> [FileEntry] {
        let floor = 10 * ByteFormatting.bytesPerMB
        let bySize = Dictionary(
            grouping: entries.filter { $0.allocatedBytes >= floor },
            by: \.allocatedBytes
        )
        return bySize.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing measured yet", systemImage: "folder")
        } description: {
            Text("These filters read the last scan rather than walking the disk again. Run a scan and the largest, oldest and same-size files appear here.")
        } actions: {
            Button("Scan for Junk") { model.startScan() }
                .buttonStyle(.borderedProminent)
                // Large, so every empty state's call to action is the same capsule.
                .controlSize(.large)
                .disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

}

// MARK: - One row

private struct LargeFileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let hasUserDataOverride: Bool
    let roundsBottomCorners: Bool
    let onToggle: (Bool) -> Void
    let onRequestUserDataOverride: () -> Void
    var onUninstallApplication: (() -> Void)?

    @State private var isRowHovered = false
    @State private var isShowingManualInfo = false

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Group {
                if entry.kind == .appBundle, let onUninstallApplication {
                    // Apps do not enter generic cleanup. The trash glyph opens the
                    // complete uninstall review and removes nothing on this click.
                    ReviewUninstallButton(
                        name: entry.displayName,
                        isRowHovered: isRowHovered,
                        action: onUninstallApplication
                    )
                } else {
                    ProtectedSelectionControl(
                        entry: entry,
                        isSelected: isSelected,
                        hasUserDataOverride: hasUserDataOverride,
                        help: rowHelp,
                        onToggle: onToggle,
                        onRequestUserDataOverride: onRequestUserDataOverride
                    )
                }
            }
            .frame(width: Metrics.selection)

            // The whole path, in monospace: at this level the decision is made on
            // location, not on a filename. Middle truncation keeps both the volume the
            // path starts in and the file it ends at.
            HStack(spacing: 7) {
                Text(FileEntry.abbreviate(entry.url.path))
                    .font(.mcMonoPath)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let manual = entry.manualRemoval {
                    Button { isShowingManualInfo = true } label: {
                        Badge(text: "terminal").fixedSize()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingManualInfo, arrowEdge: .bottom) {
                        ManualRemovalPopover(manual: manual)
                    }
                } else if let reason = entry.protectionReason {
                    Badge(text: Self.badgeText(for: reason)).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(rowHelp)\n\(entry.url.path)")

            Text(entry.kind.columnLabel)
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.quaternary)
                .lineLimit(1)
                .frame(width: Metrics.kind, alignment: .leading)

            // `fixedSize` before the frame: the column fits every value the formatter
            // produces, and a truncated size would be a lie rather than an abbreviation.
            Text(ByteFormatting.string(entry.allocatedBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Metrics.size, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.sidePadding)
        .frame(height: Token.Size.largeFileRow)
        .contentShape(Rectangle())
        // Clip only the hover paint at the box's bottom corners. Clipping the whole
        // table also clipped the first row's uninstall callout above the header.
        .background(
            isRowHovered ? Token.Fill.rowHover : .clear,
            in: UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    bottomLeading: roundsBottomCorners ? Token.Radius.box : 0,
                    bottomTrailing: roundsBottomCorners ? Token.Radius.box : 0
                )
            )
        )
        .onHover { isRowHovered = $0 }
        .zIndex(isRowHovered ? 2 : 0)
        // The row itself explains every non-checkbox state: app rows open the
        // uninstall review, terminal-managed rows show their command, and protected
        // user data opens the same warning as its orange lock.
        .onTapGesture {
            if entry.kind == .appBundle, let onUninstallApplication {
                onUninstallApplication()
            } else if entry.manualRemoval != nil {
                isShowingManualInfo = true
            } else if entry.protectionReason == .userData, !hasUserDataOverride {
                onRequestUserDataOverride()
            } else if !entry.isRemovalLocked || hasUserDataOverride {
                onToggle(!isSelected)
            }
        }
        .contextMenu {
            if entry.kind == .appBundle, let onUninstallApplication {
                Button("Review Uninstall", systemImage: "trash") {
                    onUninstallApplication()
                }
                Divider()
            }
            Button("Reveal in Finder", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }

    private var rowHelp: String {
        if entry.kind == .appBundle, onUninstallApplication != nil {
            return "Open the complete uninstall review for this application. Nothing is removed until you confirm."
        }
        if entry.manualRemoval != nil {
            return "MacCleaner cannot delete this item. Click the terminal badge for the command that can."
        }
        switch entry.protectionReason {
        case .running:
            return "This item belongs to a running app. Quit the app, then scan again to make it removable."
        case .recentUse:
            return "Used inside your protection window (Preferences › Exclusions). You can still remove it."
        case .userData:
            return hasUserDataOverride
                ? "Protected user data selected for removal. It will always move to the Trash."
                : "Contains profiles, logins, history, or settings. Use the lock to review and select it separately."
        case nil:
            return "Select this item for cleanup."
        }
    }

    private static func badgeText(for reason: FileEntry.ProtectionReason) -> String {
        switch reason {
        case .running:   "running"
        case .recentUse: "recently used"
        case .userData:  "user data"
        }
    }
}

private extension FileEntry.Kind {
    /// The design's KIND column: prose, not the enum's spelling.
    var columnLabel: String {
        switch self {
        case .file:      "File"
        case .folder:    "Folder"
        case .appBundle: "Application"
        case .cache:     "Cache"
        case .archive:   "Archive"
        case .diskImage: "Disk image"
        }
    }
}

// MARK: - Shared parts

private enum Metrics {
    static let sidePadding: CGFloat = 15
    static let gap: CGFloat = 11
    /// Matches the Scanner's 28pt checkbox/action target. App rows use this slot for
    /// the uninstall-review button without shifting the Path column.
    static let selection: CGFloat = 28
    /// Fixed, so the kinds and sizes hold their column while the path takes the growth.
    static let kind: CGFloat = 96
    static let size: CGFloat = 82
}

/// One physical pixel. `NSColor.separatorColor` is several times stronger than the
/// design's row rule; repeated every 36pt it draws a grid rather than a hint.
private struct Hairline: View {

    var body: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }
}

// MARK: - Previews

#Preview("Large & old files") {
    LargeFilesView(model: PreviewModel.scanned())
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

#Preview("No scan yet") {
    LargeFilesView(model: AppModel())
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

/// The design's own sample rows, plus a same-size pair so the Duplicates filter has
/// something to show.
@MainActor
private enum PreviewModel {
    private static func gigabytes(_ value: Double) -> Int64 {
        Int64(value * Double(ByteFormatting.bytesPerGB))
    }
    private static func daysAgo(_ days: Double) -> Date {
        Date.now.addingTimeInterval(-days * 86_400)
    }
    private static func home(_ path: String) -> URL {
        URL(filePath: NSHomeDirectory()).appending(path: path)
    }

    static func scanned() -> AppModel {
        let model = AppModel()
        model.scanResults = ScanResults(
            categories: [
                ScanCategoryResult(
                    categoryID: .documentsAndFiles,
                    totalBytes: gigabytes(20.98),
                    entries: [
                        FileEntry(
                            url: home("Downloads/Xcode_16.2.xip"),
                            kind: .archive,
                            allocatedBytes: gigabytes(8.42)
                        ),
                        FileEntry(
                            url: home("Movies/Screen Recordings"),
                            kind: .folder,
                            allocatedBytes: gigabytes(6.18),
                            lastOpened: daysAgo(400),
                            childCount: 62
                        ),
                        FileEntry(
                            url: home("Documents/Design Archive 2024"),
                            kind: .folder,
                            allocatedBytes: gigabytes(4.31),
                            lastOpened: daysAgo(243),
                            childCount: 1_204
                        ),
                        // Same allocated size as the entry below: the Duplicates filter
                        // pairs them, and neither has been read.
                        FileEntry(
                            url: home("Downloads/node_modules-backup.zip"),
                            kind: .archive,
                            allocatedBytes: gigabytes(2.07),
                            lastOpened: daysAgo(365)
                        )
                    ]
                ),
                ScanCategoryResult(
                    categoryID: .systemCaches,
                    totalBytes: gigabytes(3.69),
                    entries: [
                        FileEntry(
                            url: home("Library/Caches/Homebrew"),
                            kind: .cache,
                            allocatedBytes: gigabytes(1.62),
                            lastOpened: daysAgo(30),
                            isRegenerable: true
                        ),
                        FileEntry(
                            url: home("Library/Caches/com.apple.dt.Xcode/Downloads/archive-copy.zip"),
                            kind: .archive,
                            allocatedBytes: gigabytes(2.07),
                            lastOpened: daysAgo(12)
                        )
                    ]
                ),
                ScanCategoryResult(
                    categoryID: .docker,
                    totalBytes: gigabytes(12.90),
                    entries: [
                        FileEntry(
                            url: home("Library/Containers/com.docker.docker/Data"),
                            kind: .diskImage,
                            allocatedBytes: gigabytes(12.90),
                            lastOpened: daysAgo(2)
                        )
                    ]
                )
            ],
            startedAt: .now,
            finishedAt: .now
        )
        model.largeFilesSelection = [home("Downloads/Xcode_16.2.xip").path]
        return model
    }
}
