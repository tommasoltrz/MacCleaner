import SwiftUI
import ScoloCore

/// The Scanner categories in one grouped outline, each expanding into a
/// file table.
///
/// One box with hairline-separated rows, not the detached cards the Electron
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
                    if results.totalBytes > 0 {
                        ScanCompositionSummary(results: results)
                        // Under the bar, never above it: the bar describes the whole
                        // scan and goes on doing so while the list below it narrows.
                        filterPicker
                    }
                    // A scan that found nothing has nothing to filter, and the
                    // outline is the only one of the three that still has something
                    // to say — a category's own message, including why it is empty.
                    let filter = results.totalBytes > 0 ? model.scanFilter : .all
                    if filter != .all {
                        FilteredSummary(model: model, filter: filter)
                    }
                    // One outline for all three tabs. The other two are this one
                    // with the rows that tab does not count taken out of each
                    // category, and the categories left empty taken out with them.
                    categoryOutline(categories(of: results, for: filter))
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

    // MARK: - Filter

    /// Segmented, and sized to its labels rather than the page: this narrows a list,
    /// it does not switch between three pages.
    private var filterPicker: some View {
        Picker("Show", selection: $model.scanFilter) {
            ForEach(AppModel.ScanFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 2)
    }

    // MARK: - Sections

    /// The scan's categories as one tab shows them — see
    /// `ScanCategoryResult.filtered(safeToRemove:)`. `All` keeps every category,
    /// an empty or unavailable one included, because its message is the point there.
    private func categories(
        of results: ScanResults, for filter: AppModel.ScanFilter
    ) -> [ScanCategoryResult] {
        guard filter != .all else { return results.categories }
        return results.categories
            .map { $0.filtered(safeToRemove: filter == .safeToRemove) }
            .filter { !$0.entries.isEmpty }
    }

    @ViewBuilder
    private func categoryOutline(_ categories: [ScanCategoryResult]) -> some View {
        if categories.isEmpty {
            Text("The last scan found nothing in this group.")
                .font(.mcBody)
                .foregroundStyle(Token.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
        } else {
            outline(categories)
        }
    }

    private func outline(_ categories: [ScanCategoryResult]) -> some View {
        GroupedBox {
            VStack(spacing: 0) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    if index > 0 {
                        Divider().foregroundStyle(Token.Fill.boxBorder)
                    }
                    categorySection(category)
                }
            }
            // Without this the first and last rows' hover fill paints into the
            // box's rounded corners and squares them off.
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
        }
    }

    @ViewBuilder
    private func categorySection(_ category: ScanCategoryResult) -> some View {
        let isExpanded = model.openCategories.contains(category.categoryID)

        VStack(spacing: 0) {
            CategoryRow(
                result: category,
                isExpanded: isExpanded,
                selectedBytes: model.selectedBytes(in: category.categoryID),
                onToggle: { toggle(category) }
            )

            if isExpanded, !category.entries.isEmpty {
                FileTable(
                    entries: category.entries,
                    isSafeToRemove: category.isCountedSafe,
                    selection: $model.scannerSelection,
                    userDataRemovalOverrides: $model.userDataRemovalOverrides,
                    onUninstallApplication: { model.planAppUninstall($0.url) }
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

// MARK: - Scan composition

/// One honest part-to-whole view for the Scanner. The former row bars divided every
/// category by the largest one, which made one row 100% by definition and duplicated
/// the size column. Here every width and percentage uses the scan's actual total.
private struct ScanCompositionSummary: View {
    let results: ScanResults

    @State private var hoveredCategory: CategoryID?
    @Environment(\.colorScheme) private var colorScheme

    private var segments: [ScanCategoryResult] {
        results.categories.filter { $0.totalBytes > 0 }
    }

    private var totalBytes: Int64 {
        segments.reduce(0) { $0 + $1.totalBytes }
    }

    private var hoveredSegment: ScanCategoryResult? {
        guard let hoveredCategory else { return nil }
        return segments.first { $0.categoryID == hoveredCategory }
    }

    /// Lift a hovered colour away from the surrounding surface in either appearance.
    private var hoverLift: Double { colorScheme == .dark ? 0.12 : -0.10 }

    var body: some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 14) {
                    Text("Reclaimable space")
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)

                    Spacer(minLength: 12)

                    detail
                }

                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(segments) { segment in
                            Rectangle()
                                .fill(Token.color(segment.categoryID.color))
                                .brightness(
                                    hoveredCategory == segment.categoryID ? hoverLift : 0
                                )
                                .frame(width: segmentWidth(segment, in: geometry.size.width))
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside {
                                        hoveredCategory = segment.categoryID
                                    } else if hoveredCategory == segment.categoryID {
                                        hoveredCategory = nil
                                    }
                                }
                                .accessibilityLabel(segment.categoryID.displayName)
                                .accessibilityValue(
                                    "\(ByteFormatting.string(segment.totalBytes)), "
                                    + "\(percentageText(for: segment)) of the scan"
                                )
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: Token.Size.capacityBar)
                .background(Token.Fill.control, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
                )
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detail: some View {
        if let segment = hoveredSegment {
            HStack(spacing: 7) {
                CategoryDot(color: segment.categoryID.color, size: 8)
                Text(segment.categoryID.displayName)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                Text(
                    "\(ByteFormatting.string(segment.totalBytes)) · "
                    + percentageText(for: segment)
                )
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
            }
            .lineLimit(1)
            .transition(.opacity)
        } else {
            Text("\(ByteFormatting.string(totalBytes)) total")
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
        }
    }

    private func segmentWidth(_ segment: ScanCategoryResult, in available: CGFloat) -> CGFloat {
        guard totalBytes > 0 else { return 0 }
        return available * CGFloat(Double(segment.totalBytes) / Double(totalBytes))
    }

    private func percentageText(for segment: ScanCategoryResult) -> String {
        guard totalBytes > 0, segment.totalBytes > 0 else { return "0%" }
        let percentage = Double(segment.totalBytes) / Double(totalBytes) * 100
        if percentage < 1 { return "<1%" }
        return "\(Int(percentage.rounded()))%"
    }
}
