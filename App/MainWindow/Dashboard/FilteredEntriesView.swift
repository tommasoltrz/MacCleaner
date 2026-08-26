import SwiftUI
import MacCleanerCore

/// The list behind a Dashboard stat tile: only the entries the tile counted.
///
/// Each tile opens the items that it counts. Safe to Remove contains regenerable
/// files and verified application leftovers. Needs Review contains all other
/// files. The view uses the Scanner table and its shared selection.
struct FilteredEntriesView: View {

    enum Filter {
        case safeToRemove, needsReview

        var explanation: String {
            switch self {
            case .safeToRemove:
                "Caches and package files regenerate on demand. Application leftovers "
                    + "have no installed owner."
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
                            FileTable(
                                entries: entries,
                                selection: $model.scannerSelection,
                                userDataRemovalOverrides: $model.userDataRemovalOverrides,
                                onUninstallApplication: { model.planAppUninstall($0.url) }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        // Only this list opens pre-selected — see `seedSafeToRemoveSelection`.
        // Keyed on the scan, so a fresh scan seeds again and a return visit does
        // not overwrite what the user chose.
        .task(id: model.scanResults?.finishedAt) {
            guard filter == .safeToRemove else { return }
            model.seedSafeToRemoveSelection()
        }
    }

    private func header(_ entries: [FileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // `displayBytes`, the same arithmetic the tile above used: summing
                // what cleanup can free instead showed "0 B" over a list of
                // gigabyte rows whenever those rows were manual-removal ones.
                Text("\(entries.count) \(entries.count == 1 ? "item" : "items") · "
                     + ByteFormatting.string(entries.reduce(0) { $0 + $1.displayBytes }))
                Spacer(minLength: 12)
                Text(selectionText)
            }
            Text(filter.explanation)
        }
        .font(.mcControlLabel)
        .foregroundStyle(Token.Text.tertiary)
        .padding(.horizontal, 2)
    }

    private var selectionText: String {
        let count = model.scannerSelection.count
        guard count > 0 else { return "nothing selected yet" }
        return "\(count) selected · \(ByteFormatting.string(model.selectedBytes))"
    }

    /// The model owns this list: the status bar's Select All has to act on exactly
    /// the rows shown here, and two copies of the arithmetic would eventually
    /// disagree about what "exactly" meant.
    private var filteredEntries: [FileEntry] {
        model.tileEntries(safeToRemove: filter == .safeToRemove)
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
