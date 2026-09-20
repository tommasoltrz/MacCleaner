import SwiftUI
import ScoloCore

/// The line above the Scanner's outline when a tab narrows it: how much that tab
/// holds, and what the tab means.
///
/// This file held `FilteredEntryList`, a flat list that replaced the outline under
/// "Safe to Remove" and "Needs Review". It answered "what can I act on" and threw
/// away "where is it", which is the first thing anybody asks of a row called
/// `com.apple.helpd`. All three tabs draw the outline now — see
/// `ScannerView.categories(of:for:)` — and what is left of the list is its summary
/// and the one behaviour that was its own: the safe tab opens pre-selected.
struct FilteredSummary: View {
    @Bindable var model: AppModel
    let filter: AppModel.ScanFilter

    var body: some View {
        // The model owns this list: the status bar's Select All acts on exactly
        // these rows, and they are the rows the outline below is made of.
        let entries = model.tileEntries(safeToRemove: filter == .safeToRemove)
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
        // Only the safe tab opens pre-selected — see `seedSafeToRemoveSelection`,
        // which seeds once for each scan, so a return visit does not overwrite what
        // the user chose. Keyed on the tab as well as the scan: this view is the
        // same view under both tabs, and keyed on the scan alone it never ran when
        // the user came to "Safe to Remove" from "Needs Review".
        .task(id: SeedKey(scan: model.scanResults?.finishedAt, filter: filter)) {
            guard filter == .safeToRemove else { return }
            model.seedSafeToRemoveSelection()
        }
    }

    private struct SeedKey: Equatable {
        let scan: Date?
        let filter: AppModel.ScanFilter
    }
}
