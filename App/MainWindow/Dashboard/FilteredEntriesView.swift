import SwiftUI
import MacCleanerCore

/// The list behind a Dashboard stat tile: only the entries the tile counted.
///
/// The tiles promise two different things, so each opens onto exactly the items it
/// summed. "Safe to remove" is the regenerable categories, operable in one sweep;
/// "Needs review" is everything that requires a human. Both are real working lists,
/// not summaries: the same table, the same checkboxes, and the same shared selection
/// pool as the Scanner, so Clean Up in the status bar works here too.
struct FilteredEntriesView: View {

    enum Filter {
        case safeToRemove, needsReview

        var explanation: String {
            switch self {
            case .safeToRemove:
                "Caches, logs and package files that regenerate on demand. "
                    + "Removal loses nothing."
            case .needsReview:
                "Large files and unused apps. Look before you remove."
            }
        }
    }

    @Bindable var model: AppModel
    let filter: Filter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.scanResults == nil {
                    emptyState
                } else {
                    let entries = filteredEntries
                    header(entries)
                    if entries.isEmpty {
                        nothingHere
                    } else {
                        GroupedBox {
                            FileTable(entries: entries, selection: $model.scannerSelection)
                                .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
    }

    private func header(_ entries: [FileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(entries.count) \(entries.count == 1 ? "item" : "items") · "
                     + ByteFormatting.string(entries.reduce(0) { $0 + $1.reclaimableBytes }))
                Spacer(minLength: 12)
                Text(selectionText)
                // One gesture for the whole list. "Safe to remove" promises a sweep,
                // and a sweep should not require ticking every row by hand.
                Button(allSelected(entries) ? "Deselect All" : "Select All") {
                    toggleAll(entries)
                }
                .buttonStyle(.borderless)
                .font(.mcControlLabel)
            }
            Text(filter.explanation)
        }
        .font(.mcControlLabel)
        .foregroundStyle(Token.Text.tertiary)
        .padding(.horizontal, 2)
    }

    private func allSelected(_ entries: [FileEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { model.scannerSelection.contains($0.id) }
    }

    /// Selecting a parent strips its children from the pool — the same rule the
    /// table applies row by row — so the sweep never counts a byte twice.
    private func toggleAll(_ entries: [FileEntry]) {
        let parents = entries.map(\.id)
        let children = entries.flatMap(\.children).map(\.id)
        if allSelected(entries) {
            model.scannerSelection.subtract(parents)
        } else {
            model.scannerSelection.formUnion(parents)
        }
        model.scannerSelection.subtract(children)
    }

    private var selectionText: String {
        let count = model.scannerSelection.count
        guard count > 0 else { return "nothing selected yet" }
        return "\(count) selected · \(ByteFormatting.string(model.selectedBytes))"
    }

    /// The same arithmetic as the tile, so the list always sums to the figure the
    /// user clicked. Deduplicated by path: an entry two categories both claim is
    /// one thing to remove, not two.
    private var filteredEntries: [FileEntry] {
        guard let results = model.scanResults else { return [] }
        let wantSafe = filter == .safeToRemove
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .filter { $0.categoryID.isSafe == wantSafe }
            .flatMap(\.entries)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    private var nothingHere: some View {
        Text("The last scan found nothing in this group.")
            .font(.mcBody)
            .foregroundStyle(Token.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing scanned yet", systemImage: "magnifyingglass")
        } description: {
            Text("Run a scan first. This list shows only what the scan counted.")
        } actions: {
            Button("Scan for Junk") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
