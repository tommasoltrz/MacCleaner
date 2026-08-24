import SwiftUI
import MacCleanerCore

/// The Scanner: all seven categories in one grouped outline, each expanding into a
/// file table.
///
/// One box with hairline-separated rows, not the seven detached cards the Electron
/// version used — the design is explicit that this should read like Finder or System
/// Settings, where a list of things is a list, not a scattering of panels.
struct ScannerView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // No header before the first scan: "No scan yet · nothing selected
                // yet" above the empty state said the same thing twice, and Large &
                // Old Files already shows this state bare.
                if let results = model.scanResults {
                    header
                    GroupedBox {
                        VStack(spacing: 0) {
                            ForEach(Array(results.categories.enumerated()), id: \.element.id) { index, category in
                                if index > 0 {
                                    Divider().foregroundStyle(Token.Fill.boxBorder)
                                }
                                categorySection(category, largest: largestBytes(in: results))
                            }
                        }
                        // Without this the first and last rows' hover fill paints
                        // into the box's rounded corners and squares them off.
                        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        .task { model.pruneVanishedEntries() }
    }

    // MARK: - Header line

    private var header: some View {
        HStack {
            Text(summaryText)
            Spacer(minLength: 12)
            Text(selectionText)
        }
        .font(.mcControlLabel)
        .foregroundStyle(Token.Text.tertiary)
        .padding(.horizontal, 2)
    }

    private var summaryText: String {
        guard let results = model.scanResults else { return "No scan yet" }
        let actionable = results.actionableCategories.count
        let volume = model.volume?.name ?? "this Mac"
        return "\(actionable) categories · \(ByteFormatting.string(results.totalBytes)) found on \(volume)"
    }

    /// Live, and derived rather than stored — the design lists every selection
    /// readout as computed.
    private var selectionText: String {
        let count = model.scannerSelection.count
        guard count > 0 else { return "nothing selected yet" }
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) selected · \(ByteFormatting.string(model.selectedBytes))"
    }

    // MARK: - Sections

    @ViewBuilder
    private func categorySection(_ category: ScanCategoryResult, largest: Int64) -> some View {
        let isExpanded = model.openCategories.contains(category.categoryID)

        VStack(spacing: 0) {
            CategoryRow(
                result: category,
                largestBytes: largest,
                isExpanded: isExpanded,
                selectedBytes: model.selectedBytes(in: category.categoryID),
                onToggle: { toggle(category) }
            )

            if isExpanded, !category.entries.isEmpty {
                FileTable(
                    entries: category.entries,
                    selection: $model.scannerSelection,
                    userDataRemovalOverrides: $model.userDataRemovalOverrides,
                    appDataRemovalOverrides: $model.appDataRemovalOverrides
                )
            }
        }
    }

    private func toggle(_ category: ScanCategoryResult) {
        guard category.availability.isActionable, !category.entries.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if model.openCategories.contains(category.categoryID) {
                model.openCategories.remove(category.categoryID)
            } else {
                model.openCategories.insert(category.categoryID)
            }
        }
    }

    /// The proportion bars are relative to the biggest category, not to the disk.
    private func largestBytes(in results: ScanResults) -> Int64 {
        results.categories.map(\.totalBytes).max() ?? 1
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing scanned yet", systemImage: "magnifyingglass")
        } description: {
            Text("Scan for Junk measures caches, unused apps and large files. Nothing is removed without your approval.")
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
