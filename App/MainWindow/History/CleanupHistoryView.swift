import SwiftUI
import ScoloCore

/// Shows a read-only record of Scolo removal results.
struct CleanupHistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Filters the rows and their size total.
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all

    /// Opens newest first, which is the order the log is read in.
    @State private var sortKey: SortKey = .date
    @State private var ascending = false

    private enum SortKey { case name, result, date, size }

    /// The Scanner's rule: a second click flips the column; a new column opens in
    /// the direction it is usually wanted — largest and newest first, names and
    /// results from the top.
    private func adopt(_ key: SortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = (key == .name || key == .result)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.history.isLoadingCleanupHistory && model.history.cleanupHistory == nil {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else if visibleItems.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No matching items",
                            systemImage: filter.symbol,
                            description: Text("No history items match this filter.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .operationPageLayout()
            } else {
                historyTable
            }
        }
        .task { await model.history.loadCleanupHistory() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.history.loadCleanupHistory() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { choice in
                    PageTabPill(
                        title: choice.rawValue,
                        symbol: choice.symbol,
                        detail: "\(items.filter { choice.includes($0.state) }.count)",
                        isSelected: filter == choice
                    ) { filter = choice }
                    .help(choice.helpText)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                if let summary = model.history.cleanupHistory {
                    let visible = visibleItems
                    let bytes = visible.reduce(Int64(0)) { $0 + $1.bytes }
                    Text("\(visible.count) \(visible.count == 1 ? "item" : "items") · \(ByteFormatting.string(bytes))")
                        .font(.mcControlLabel)
                        .foregroundStyle(Token.Text.secondary)
                        .help(summaryText(summary))
                }
                Spacer(minLength: 12)
                FindField(text: $searchText, findRequest: model.findRequest)
                    .frame(width: 180)
                    .disabled(items.isEmpty)
            }
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.top, Token.Size.pageGutter)
        .padding(.bottom, 12)
    }

    /// The Trash view's list, not a native `Table`. `Table` paints its own backdrop —
    /// the window material, which takes the desktop's tint — so this one page stood
    /// brown against the opaque canvas every other page sits on, with AppKit's header
    /// and alternating stripes where the rest of the app has a grouped box.
    private var historyTable: some View {
        ScrollView {
            GroupedBox {
                VStack(spacing: 0) {
                    columnHeader
                    Hairline()
                    // Lazy: the log is read 5,000 records deep.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 0) {
                                if index > 0 { Hairline() }
                                HistoryRow(item: item, onShowInTrash: { model.trash.showInTrash(item) })
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
            }
            .padding(.horizontal, Token.Size.pageGutter)
            .padding(.top, 2)
            .padding(.bottom, 22)
        }
        // Reset cached row positions when the visible set changes.
        .id([filter.rawValue, query])
    }

    /// Column labels use the same style as the other file lists.
    private var columnHeader: some View {
        HStack(spacing: Metrics.gap) {
            sortHeader("Item", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Result", .result)
                .frame(width: Metrics.result, alignment: .leading)
            sortHeader("Date", .date)
                .frame(width: Metrics.date, alignment: .leading)
            sortHeader("Size", .size)
                .frame(width: Metrics.size, alignment: .trailing)
        }
        .font(.mcControlLabel)
        .foregroundStyle(Token.Text.tertiary)
        .padding(.horizontal, Metrics.sidePadding)
        .padding(.vertical, 10)
    }

    private func sortHeader(_ title: String, _ key: SortKey) -> some View {
        SortableColumnHeader(
            title: title,
            isActive: sortKey == key,
            ascending: ascending,
            action: { adopt(key) }
        )
    }

    private var loadingState: some View {
        PageProgressView(title: "Reading cleanup history")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No cleanup history", systemImage: "clock")
        } description: {
            Text("Enable Put Back receipts in Settings to record removed items and failures.")
        }
        .operationPageLayout()
    }

    private var items: [CleanupHistoryItem] {
        model.history.cleanupHistory?.items ?? []
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Name or original folder: "where did that file from Downloads go" is asked by
    /// place as often as by name, and the row shows both.
    private var visibleItems: [CleanupHistoryItem] {
        let matching = items.filter {
            filter.includes($0.state)
                && (query.isEmpty || $0.originalURL.path.localizedCaseInsensitiveContains(query))
        }
        return sorted(matching)
    }

    /// Every key but the date falls back to newest first, so the rows inside one
    /// result — several hundred "No longer in Trash" here — keep a readable order
    /// instead of whatever the sort left them in. The fallback does not flip with
    /// the column: reversing "Result" should not also turn its groups oldest first.
    private func sorted(_ items: [CleanupHistoryItem]) -> [CleanupHistoryItem] {
        items.sorted { a, b in
            let order: ComparisonResult = switch sortKey {
            case .name:   a.name.localizedStandardCompare(b.name)
            case .result: compare(a.state.sortRank, b.state.sortRank)
            case .date:   compare(a.timestamp, b.timestamp)
            case .size:   compare(a.bytes, b.bytes)
            }
            if order == .orderedSame { return a.timestamp > b.timestamp }
            return (order == .orderedAscending) == ascending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private func summaryText(_ summary: CleanupHistorySummary) -> String {
        var parts = [
            "\(summary.removedCount) \(summary.removedCount == 1 ? "item" : "items") removed",
            "Removed size \(ByteFormatting.string(summary.removedBytes))",
        ]
        // Only when the two figures actually part company. They agree for every
        // ordinary removal, and repeating one number twice would read as a defect;
        // they diverge when APFS was sharing the removed files' blocks with copies
        // that are still on the disk, and then the second number is the true one.
        if summary.freedBytes != summary.removedBytes {
            parts.append("Freed \(ByteFormatting.string(summary.freedBytes))")
        }
        parts.append("\(summary.availableInTrashCount) available in Trash")
        if summary.permanentlyRemovedCount > 0 {
            parts.append("\(summary.permanentlyRemovedCount) permanent")
        }
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) failed")
        }
        return parts.joined(separator: " · ")
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inTrash = "In Trash"
    case restored = "Restored"
    case failed = "Failed"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .inTrash: "trash"
        case .restored: "arrow.uturn.backward"
        case .failed: "exclamationmark.circle"
        }
    }

    var helpText: String {
        switch self {
        case .all: "All recorded removal results."
        case .inTrash: "Items that are still in the Trash."
        case .restored: "Items that Scolo restored from the Trash to their original locations."
        case .failed: "Items that Scolo could not remove."
        }
    }

    func includes(_ state: CleanupHistoryState) -> Bool {
        switch self {
        case .all: true
        case .inTrash: state == .availableInTrash || state == .inTrash
        case .restored: state == .restored
        case .failed: state == .failed
        }
    }
}

private extension CleanupHistoryState {
    /// What can still be acted on first, then what went wrong, then the settled
    /// outcomes. Alphabetical by label would put "Available in Trash" and "In Trash"
    /// either side of "Could not remove".
    var sortRank: Int {
        switch self {
        case .availableInTrash:   0
        case .inTrash:            1
        case .failed:             2
        case .restored:           3
        case .removedPermanently: 4
        case .noLongerInTrash:    5
        }
    }
}

private struct HistoryRow: View {
    let item: CleanupHistoryItem
    let onShowInTrash: () -> Void

    var body: some View {
        HStack(spacing: Metrics.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FileEntry.abbreviate(item.originalURL.deletingLastPathComponent().path))
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.originalURL.path)

            Group {
                if item.state == .availableInTrash, item.trashedURL != nil {
                    Button(action: onShowInTrash) {
                        Label("Show in Trash", systemImage: "trash")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Open the Trash and select this item.")
                    .accessibilityHint("Selects \(item.name) in the Trash view.")
                } else {
                    ResultLabel(state: item.state)
                }
            }
            .font(.mcSubtitle)
            .frame(width: Metrics.result, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.timestamp, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundStyle(Token.Text.secondary)
                Text(item.timestamp, format: .dateTime.hour().minute())
                    .foregroundStyle(Token.Text.tertiary)
            }
            .font(.mcSubtitle)
            .lineLimit(1)
            .frame(width: Metrics.date, alignment: .leading)

            Text(item.bytes > 0 ? ByteFormatting.string(item.bytes) : "—")
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Metrics.size, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.sidePadding)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .hoverHighlight()
    }
}

/// Shared widths keep the column labels and values aligned.
private enum Metrics {
    static let sidePadding: CGFloat = 18
    static let gap: CGFloat = 11
    static let result: CGFloat = 160
    static let date: CGFloat = 110
    static let size: CGFloat = 78
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }
}

private struct ResultLabel: View {
    let state: CleanupHistoryState

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(helpText)
    }

    private var title: String {
        switch state {
        case .availableInTrash: "Available in Trash"
        case .inTrash: "In Trash"
        case .restored: "Restored"
        case .removedPermanently: "Removed permanently"
        case .noLongerInTrash: "No longer in Trash"
        case .failed: "Could not remove"
        }
    }

    private var symbol: String {
        switch state {
        case .availableInTrash: "trash"
        case .inTrash: "trash"
        case .restored: "checkmark.circle"
        case .removedPermanently: "trash.slash"
        case .noLongerInTrash: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch state {
        case .availableInTrash: Token.textColor(.green)
        case .failed: Token.textColor(.orange)
        case .restored: Token.Text.secondary
        case .inTrash, .removedPermanently, .noLongerInTrash: Token.Text.tertiary
        }
    }

    private var helpText: String {
        switch state {
        case .availableInTrash:
            "The receipt matches this item in the Trash. Use the Trash view to put it back."
        case .inTrash:
            "The Trash path exists, but the receipt cannot prove that it contains the same item."
        case .restored:
            "Scolo put this item back at its original location."
        case .removedPermanently:
            "This item did not move to the Trash, so it cannot be put back."
        case .noLongerInTrash:
            "This receipt no longer matches an item in the Trash."
        case .failed:
            "Scolo did not remove this item."
        }
    }
}
