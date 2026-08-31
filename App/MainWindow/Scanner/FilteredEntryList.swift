import SwiftUI
import ScoloCore

/// The Scanner's results as one flat list, narrowed to what a filter counts.
///
/// The grouped outline beside it answers "what was found, and where"; this answers
/// "what can I act on", so it drops the category structure and sorts by size. Both
/// draw the same rows from the same `ScanResults` and share one selection, and the
/// Scanner chooses between them.
struct FilteredEntryList: View {
    @Bindable var model: AppModel
    let filter: AppModel.ScanFilter

    var body: some View {
        let entries = filteredEntries
        VStack(alignment: .leading, spacing: 12) {
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
            // `displayBytes`, the same arithmetic the Dashboard tile uses: summing
            // what cleanup can free instead showed "0 B" over a list of gigabyte
            // rows whenever those rows were manual-removal ones.
            Text("\(entries.count) \(entries.count == 1 ? "item" : "items") · "
                 + ByteFormatting.string(entries.reduce(0) { $0 + $1.displayBytes }))
            if let explanation = filter.explanation {
                Text(explanation)
            }
        }
        .font(.mcControlLabel)
        .foregroundStyle(Token.Text.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
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
}
