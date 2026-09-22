import SwiftUI
import ScoloCore

/// Keeps the cleanup filters above the file list.
struct ScannerView: View {
    @Bindable var model: AppModel
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resultsVisible = true

    var body: some View {
        Group {
            if case .cleaningUp(let itemCount, let totalBytes) = model.activity {
                CleanupOperationView(itemCount: itemCount, totalBytes: totalBytes)
                    .transition(.opacity)
            } else if let completion = model.cleanupCompletion {
                CleanupOperationView(
                    itemCount: completion.outcome.removedCount,
                    totalBytes: completion.outcome.removedBytes,
                    isComplete: true,
                    canScan: !model.isBusyWithDisk,
                    onScanAgain: { model.startScan() },
                    onViewDashboard: { model.showDashboardAfterCleanup(completion.id) }
                )
                .id(completion.id)
                .transition(.opacity)
            } else if model.isScanning {
                scanProgress
                    .transition(.opacity)
            } else if let results = model.scanResults {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        if let outcome = model.cleanupOutcome {
                            completion(outcome).modifier(resultEntrance(index: 0))
                        }
                        filterPicker(results)
                            .modifier(resultEntrance(index: 0))
                        listControls(results)
                            .padding(.top, 8)
                            .modifier(resultEntrance(index: 1))
                    }
                    .padding(Token.Size.pageGutter)
                    Divider()
                        .opacity(resultsVisible ? 1 : 0)
                    let visibleCategories = categories(of: results, for: model.scanFilter)
                    let showsRunningApps = model.scanFilter == .safeToRemove && !model.runningAppCaches.isEmpty
                    let showsEmptyState = hasNoCleanupItems(visibleCategories) && !showsRunningApps
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 12) {
                                if showsRunningApps {
                                    runningAppsNotice
                                        .modifier(resultEntrance(index: 2))
                                }
                                categoryOutline(visibleCategories)
                            }
                            .frame(minHeight: showsEmptyState ? geometry.size.height : 0, alignment: .top)
                            .padding(showsEmptyState ? 0 : Token.Size.pageGutter)
                        }
                    }
                }
                .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label("Ready to scan", systemImage: "magnifyingglass")
                } description: {
                    Text("Use Scan to find cleanup items.")
                }
                .pageStateLayout()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.scanResults?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.scanResults?.finishedAt != nil
                    && model.scanResults?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.scanFilter) { _, _ in animateEmptyResult = false }
        .onDisappear { animateEmptyResult = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsOperation)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.cleanupCompletion?.id)
        .task {
            model.pruneVanishedEntries()
            model.refreshCleanupRunningOwners()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshCleanupRunningOwners()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshCleanupRunningOwners()
        }
        .task(id: model.isScanning) {
            if model.isScanning {
                resultsVisible = false
                return
            }
            model.refreshCleanupRunningOwners()
            guard !resultsVisible else { return }
            if !reduceMotion {
                // Show the initial layout before the entrance animation starts.
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            resultsVisible = true
        }
        .onDisappear { resultsVisible = true }
    }

    private var runningAppsNotice: some View {
        let names = ListFormatter.localizedString(byJoining: model.cleanupRunningOwners.map(\.name))
        let bytes = model.runningAppCaches.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        return GroupedBox {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Some apps are using cached files")
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text("\(names) · \(ByteFormatting.string(bytes)) of caches")
                        .font(.mcControlLabel)
                        .foregroundStyle(Token.Text.secondary)
                        .lineLimit(2)
                        .help(names)
                    Text("Save your work before you quit these apps. Their caches will appear in Safe to Remove.")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Quit Apps") {
                    Task { await model.quitAppsForCleanup() }
                }
                    .buttonStyle(PageActionButtonStyle())
                    .fixedSize()
                    .disabled(model.isBusyWithDisk)
            }
            .padding(14)
        }
    }

    private var showsOperation: Bool {
        model.isScanning || model.isCleaningUp || model.cleanupCompletion != nil
    }

    private var scanProgress: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scanning for cleanup items")
                    .font(.system(size: 18, weight: .medium))
                Spacer()
                Text("\(model.scanProgress)%")
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            ProgressView(value: Double(model.scanProgress), total: 100)
                .progressViewStyle(.linear)
                .tint(Token.Text.primary)
                .accessibilityLabel("Cleanup scan")
                .accessibilityValue("\(model.scanProgress)%")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.scanProgress)
        .frame(maxWidth: 380)
        .operationPageLayout()
    }

    private func resultEntrance(index: Int) -> ResultEntrance {
        ResultEntrance(isVisible: resultsVisible, index: index, reduceMotion: reduceMotion)
    }

    private func listControls(_ results: ScanResults) -> some View {
        let visible = categories(of: results, for: model.scanFilter)
        let count = visible.reduce(0) { $0 + $1.entries.count }
        return HStack(spacing: 12) {
            MonochromeCheckbox(
                title: "Select All",
                detail: "\(count) \(count == 1 ? "item" : "items")",
                state: model.hasSelectableItemsInCurrentView && !model.canSelectAllInCurrentView
                    ? .on : .off,
                isEnabled: !model.isBusyWithDisk
                    && (model.hasSelectableItemsInCurrentView || model.hasSelectionInCurrentView)
            ) { isOn in
                if isOn { model.selectAllInCurrentView() }
                else { model.deselectAllInCurrentView() }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.leading, 15)
    }

    private func completion(_ outcome: CleanupOutcome) -> some View {
        HStack(spacing: 12) {
            Text("\(ByteFormatting.string(outcome.removedBytes)) moved to Trash")
                .font(.mcRowTitle)
            if !outcome.failed.isEmpty {
                Text("\(outcome.failed.count) items could not be removed.")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Filter

    /// Filters stay visible while the file list scrolls.
    private func filterPicker(_ results: ScanResults) -> some View {
        HStack(spacing: 8) {
            ForEach(AppModel.ScanFilter.allCases) { filter in
                filterPill(filter, results: results)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isBusyWithDisk)
    }

    private func filterPill(_ filter: AppModel.ScanFilter, results: ScanResults) -> some View {
        let isSelected = model.scanFilter == filter
        let tint: Color = switch filter {
        case .all: Token.textColor(.accent)
        case .safeToRemove: Token.textColor(.green)
        case .needsReview: Token.textColor(.orange)
        }
        let symbol = switch filter {
        case .all: "square.grid.2x2"
        case .safeToRemove: "checkmark.circle.fill"
        case .needsReview: "questionmark.circle"
        }
        let size = ByteFormatting.string(bytes(in: filter, results: results))

        return PageTabPill(
            title: filter.title, symbol: symbol, detail: size,
            isSelected: isSelected, tint: tint
        ) { model.scanFilter = filter }
    }

    private func bytes(in filter: AppModel.ScanFilter, results: ScanResults) -> Int64 {
        switch filter {
        case .all: results.totalBytes
        case .safeToRemove: results.safeToRemoveBytes
        case .needsReview: results.needsReviewBytes
        }
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

    private func hasNoCleanupItems(_ categories: [ScanCategoryResult]) -> Bool {
        categories.allSatisfy {
            $0.entries.isEmpty && $0.unreadableCount == 0
                && ($0.availability == .available || $0.availability == .empty)
        }
    }

    @ViewBuilder
    private func categoryOutline(_ categories: [ScanCategoryResult]) -> some View {
        if hasNoCleanupItems(categories) {
            ScanCompletionView(
                title: model.scanFilter == .safeToRemove ? "No safe cleanup items found" : "No cleanup items found",
                detail: "The scan found no items in this group.",
                animate: animateEmptyResult
            )
        } else {
            outline(categories)
        }
    }

    private func outline(_ categories: [ScanCategoryResult]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                GroupedBox {
                    categorySection(category)
                        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                }
                .modifier(resultEntrance(index: index + 2))
            }
        }
    }

    @ViewBuilder
    private func categorySection(_ category: ScanCategoryResult) -> some View {
        let isExpanded = model.openCategories.contains(category.categoryID)

        VStack(spacing: 0) {
            CategoryRow(
                result: category,
                isExpanded: isExpanded,
                selectedBytes: model.selectedBytes(in: category.categoryID, filter: model.scanFilter),
                onToggle: { toggle(category) }
            )

            if isExpanded, !category.entries.isEmpty {
                FileTable(
                    entries: category.entries,
                    isSafeToRemove: category.isCountedSafe,
                    showsSafeToRemoveBadges: model.scanFilter != .safeToRemove,
                    selection: $model.scannerSelection,
                    userDataRemovalOverrides: $model.userDataRemovalOverrides,
                    onUninstallApplication: { model.planAppUninstall($0.url) }
                )
                .id(model.scanFilter)
                .disabled(model.isBusyWithDisk)
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

}

private struct ResultEntrance: ViewModifier {
    var isVisible: Bool
    var index: Int
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 6)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.24).delay(Double(min(index, 7)) * 0.035),
                value: isVisible
            )
    }
}
