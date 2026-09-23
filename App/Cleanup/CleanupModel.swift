import AppKit
import Observation
import ScoloCore

/// Owns cleanup scans, filters, and selection.
@MainActor
@Observable
final class CleanupModel {
    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onFailure: ((String, String) -> Void)?
    @ObservationIgnored private var currentScanID: UUID?
    private var isCancellingScan = false

    init(settings: SettingsStore? = nil, scanner: (any CleanupScanning)? = nil, defaults: UserDefaults = .standard) {
        self.scanner = scanner ?? CleanupScanner(settings: settings)
        self.defaults = defaults
        self.lastScanFinishedAt = defaults.object(forKey: "lastScanFinishedAt") as? Date
    }

    var needsInitialScan: Bool { scanResults == nil && !hasStartedInitialCleanupScan }

    func invalidateAfterRemoval() {
        scanResults = nil
        deselectAll()
        cleanupRunningOwners = []
        scanFilter = .safeToRemove
        hasStartedInitialCleanupScan = false
    }

    func applyRemoval(_ outcome: CleanupOutcome, entries: [FileEntry]) {
        let removed = Set(entries.map(\.id)).subtracting(outcome.failed)
        scannerSelection.subtract(removed)
        userDataRemovalOverrides.subtract(removed)
        if var results = scanResults {
            results.categories = results.categories.map { category in
                var copy = category
                copy.entries.removeAll { removed.contains($0.id) }
                copy.entries = copy.entries.map { entry in
                    var entry = entry
                    entry.children.removeAll { removed.contains($0.id) }
                    return entry
                }
                copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
                return copy
            }
            scanResults = results
        }
        pruneVanishedEntries()
    }

    enum ScanFilter: String, CaseIterable, Identifiable {
        case all, safeToRemove, needsReview
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:          "All"
            case .safeToRemove: "Safe to Remove"
            case .needsReview:  "Needs Review"
            }
        }

        /// What this lens holds, in one line. `all` has none: the header and the
        /// composition bar above it already describe the whole scan.
        var explanation: String? {
            switch self {
            case .all:
                nil
            case .safeToRemove:
                "Caches and package files. They regenerate on demand, so removing them costs nothing."
            case .needsReview:
                "Large files, unused apps and what removed apps left behind. Look before you remove."
            }
        }
    }

    var scanFilter: ScanFilter = .safeToRemove

    private(set) var scanResults: ScanResults?

    private(set) var lastScanFinishedAt: Date?

    private(set) var isScanning = false

    private(set) var scanProgress = 0

    var openCategories: Set<CategoryID> = [.documentsAndFiles]

    var scannerSelection: Set<FileEntry.ID> = []

    var userDataRemovalOverrides: Set<FileEntry.ID> = []

    var allEntries: [FileEntry] {
        let tops = scanResults?.categories.flatMap(\.entries) ?? []
        // Children are selectable in their own right (removing an app's cache while
        // keeping the app), so they must resolve from the selection set too. A
        // selected parent strips its children from the set, so nothing double-counts.
        return tops + tops.flatMap(\.children)
    }

    var selectedEntries: [FileEntry] {
        let selected = scannerSelection
        // Application bundles use the dedicated uninstaller. Their disclosed
        // children remain ordinary cleanup rows, but a stale app ID can never
        // reach the generic cleanup service.
        return allEntries.filter {
            selected.contains($0.id)
                && $0.kind != .appBundle
                && $0.removalAction == nil
        }
    }

    var selectedOrphanApplicationEntries: [FileEntry] {
        let selected = scannerSelection
        return scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .entries.filter { selected.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 {
        selectedEntries.reduce(0) { $0 + plannedBytes(for: $1) }
            + selectedOrphanApplicationEntries.reduce(0) { $0 + $1.displayBytes }
    }

    private func plannedTargets(for entry: FileEntry) -> [FileEntry] {
        CleanupService.removalTargets(
            for: entry,
            removeProtectedAppData: false
        )
    }

    private func plannedBytes(for entry: FileEntry) -> Int64 {
        plannedTargets(for: entry).reduce(0) { $0 + $1.allocatedBytes }
    }

    var hasSelection: Bool {
        !selectedEntries.isEmpty || !selectedOrphanApplicationEntries.isEmpty
    }

    func selectedBytes(in category: CategoryID, filter: ScanFilter = .all) -> Int64 {
        let selected = cleanupSelection(in: filter)
        guard let result = scanResults?.categories.first(where: { $0.categoryID == category })
        else { return 0 }
        let entries = filter == .all
            ? result.entries : result.tileRows(safeToRemove: filter == .safeToRemove)
        if category == .applicationLeftovers {
            return entries
                .filter { selected.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
        }
        return entries.reduce(Int64(0)) { total, entry in
            if selected.contains(entry.id) {
                let targets = plannedTargets(for: entry)
                let covered = Set(targets.map(\.id))
                // A protected child may be unlocked individually after selecting
                // “keep data” for its parent. It is not covered by the parent's
                // plan, so count that explicit child selection too.
                let extraChildren = entry.children
                    .filter { selected.contains($0.id) && !covered.contains($0.id) }
                    .reduce(0) { $0 + plannedBytes(for: $1) }
                return total + targets.reduce(0) { $0 + $1.allocatedBytes } + extraChildren
            }
            // Individually selected children count toward their category's readout.
            return total + entry.children
                .filter { selected.contains($0.id) }
                .reduce(0) { $0 + $1.allocatedBytes }
        }
    }

    func pruneVanishedEntries() {
        guard var results = scanResults else { return }
        let fileManager = FileManager.default
        var vanished: Set<FileEntry.ID> = []

        results.categories = results.categories.map { category in
            var copy = category
            copy.entries = copy.entries.compactMap { original in
                var entry = original
                if entry.removalAction != nil {
                    entry.children.removeAll {
                        !fileManager.fileExists(atPath: $0.url.path)
                    }
                    guard !entry.children.isEmpty else {
                        vanished.insert(entry.id)
                        return nil
                    }
                    entry.url = entry.children[0].url
                    entry.childCount = entry.children.count
                    return entry
                }
                // Synthetic rows (Docker's accounting, manual-removal aggregates)
                // keep their place; only real paths are checked.
                guard entry.url.isFileURL, entry.manualRemoval == nil else { return entry }
                let gone = !fileManager.fileExists(atPath: entry.url.path)
                if gone { vanished.insert(entry.id) }
                return gone ? nil : entry
            }
            copy.entries = copy.entries.map { entry in
                var entry = entry
                entry.children.removeAll { child in
                    let gone = !fileManager.fileExists(atPath: child.url.path)
                    if gone { vanished.insert(child.id) }
                    return gone
                }
                return entry
            }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            return copy
        }

        if !vanished.isEmpty {
            scanResults = results
            scannerSelection.subtract(vanished)
            userDataRemovalOverrides.subtract(vanished)
        }
    }

    func tileEntries(safeToRemove wantSafe: Bool) -> [FileEntry] {
        guard let results = scanResults else { return [] }
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .flatMap { $0.tileRows(safeToRemove: wantSafe) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayBytes > $1.displayBytes }
    }

    private var rowsInCurrentView: [FileEntry] {
        switch scanFilter {
        case .all: scanResults?.categories.flatMap(\.entries) ?? []
        case .safeToRemove: tileEntries(safeToRemove: true)
        case .needsReview: tileEntries(safeToRemove: false)
        }
    }

    private var selectableInCurrentView: [FileEntry] {
        let rows = rowsInCurrentView
        let candidates = scanFilter == .all
            ? rows + tileEntries(safeToRemove: true) : rows
        var seen = Set<FileEntry.ID>()
        let selectable = candidates.filter {
            !$0.isRemovalLocked && $0.kind != .appBundle && seen.insert($0.id).inserted
        }
        let covered = Set(selectable.flatMap(\.children).map(\.id))
        return selectable.filter { !covered.contains($0.id) }
    }

    func cleanupSelection(in filter: ScanFilter) -> Set<FileEntry.ID> {
        let scope: CleanupSelection.Scope = switch filter {
        case .all: .all
        case .safeToRemove: .safe
        case .needsReview: .review
        }
        return CleanupSelection.ids(
            in: scanResults?.categories ?? [], selected: scannerSelection, scope: scope
        )
    }

    func cleanupSelectionBytes(in filter: ScanFilter) -> Int64 {
        let ids = cleanupSelection(in: filter)
        return selectedEntries.filter { ids.contains($0.id) }
            .reduce(0) { $0 + plannedBytes(for: $1) }
            + selectedOrphanApplicationEntries.filter { ids.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
    }

    var canSelectAllInCurrentView: Bool {
        let selectable = selectableInCurrentView
        return !selectable.isEmpty
            && !selectable.allSatisfy { scannerSelection.contains($0.id) }
    }

    var hasSelectableItemsInCurrentView: Bool { !selectableInCurrentView.isEmpty }

    var hasSelectionInCurrentView: Bool {
        let rows = rowsInCurrentView
        return (rows + rows.flatMap(\.children)).contains { scannerSelection.contains($0.id) }
    }

    func deselectAllInCurrentView() {
        let rows = rowsInCurrentView
        let ids = Set((rows + rows.flatMap(\.children)).map(\.id))
        scannerSelection.subtract(ids)
        userDataRemovalOverrides.subtract(ids)
    }

    @ObservationIgnored private var safeSelectionSeededAt: Date?

    func seedSafeToRemoveSelection() {
        guard let finishedAt = scanResults?.finishedAt,
              safeSelectionSeededAt != finishedAt
        else { return }
        safeSelectionSeededAt = finishedAt

        // Everything under this tab is ticked, because everything under it costs
        // nothing to remove. Application leftovers used to sit here unticked — safe
        // by one meaning and not by the other — and are under Needs Review now; the
        // `removalAction` test stays as a guard, since a leftover group is never
        // removed through the ordinary selection.
        let selectable = tileEntries(safeToRemove: true).filter {
            !$0.isRemovalLocked && $0.kind != .appBundle && $0.removalAction == nil
        }
        guard !selectable.isEmpty else { return }
        scannerSelection.formUnion(selectable.map(\.id))
        // Parent selection replaces individual child selection so cleanup never
        // counts the same bytes twice.
        let childIDs = Set(selectable.flatMap(\.children).map(\.id))
        scannerSelection.subtract(childIDs)
        userDataRemovalOverrides.subtract(childIDs)
    }

    func selectAllInCurrentView() {
        let selectable = selectableInCurrentView
        guard !selectable.isEmpty else { return }
        scannerSelection.formUnion(selectable.map(\.id))
        let childIDs = Set(selectable.flatMap(\.children).map(\.id))
        scannerSelection.subtract(childIDs)
        userDataRemovalOverrides.subtract(childIDs)
    }

    func deselectAll() {
        scannerSelection.removeAll()
        userDataRemovalOverrides.removeAll()
    }

    private(set) var cleanupRunningOwners: [FileEntry.RunningOwner] = []

    private var runningCacheCandidates: [FileEntry] {
        var candidates: [FileEntry] = []
        var seen: Set<FileEntry.ID> = []
        func visit(_ entry: FileEntry) {
            guard entry.removalAction == nil, !entry.removesAsUnit,
                  entry.manualRemoval == nil, entry.protectionReason != .userData else { return }
            if !entry.children.isEmpty {
                entry.children.forEach(visit)
                return
            }
            guard entry.kind != .appBundle, entry.isRegenerable,
                  !entry.isRemovalLocked, entry.inUseBy != nil,
                  entry.allocatedBytes > 0, seen.insert(entry.id).inserted else { return }
            candidates.append(entry)
        }
        scanResults?.categories.flatMap(\.entries).forEach(visit)
        return candidates
    }

    var runningAppCaches: [FileEntry] {
        let owners = Set(cleanupRunningOwners)
        return runningCacheCandidates.filter { entry in
            entry.inUseBy.map { owners.contains($0) } ?? false
        }
    }

    func refreshCleanupRunningOwners() {
        let known = Array(Set(runningCacheCandidates.compactMap(\.inUseBy)))
        let live = ApplicationRuntime.stillRunning(known)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cleanupRunningOwners = live
    }

    func clearInUse(of owners: [FileEntry.RunningOwner]) {
        guard var results = scanResults else { return }
        let gone = Set(owners)
        func cleared(_ entry: FileEntry) -> FileEntry {
            var entry = entry
            if let owner = entry.inUseBy, gone.contains(owner) { entry.inUseBy = nil }
            entry.children = entry.children.map(cleared)
            return entry
        }
        results.categories = results.categories.map { category in
            var copy = category
            copy.entries = category.entries.map(cleared)
            return copy
        }
        scanResults = results
    }

    var categorySizes: [CategoryID: Int64] {
        guard let results = scanResults else { return [:] }
        return Dictionary(uniqueKeysWithValues: results.categories.map { ($0.categoryID, $0.totalBytes) })
    }


    private var scanTask: Task<Void, Never>?

    func startScan() {
        // AppModel checks shared operations before it starts this scan.
        guard !isScanning else { return }
        hasStartedInitialCleanupScan = true
        // An override belongs to one reviewed result set. Carrying it into a fresh
        // scan would turn a newly discovered row into an authorized deletion merely
        // because it reused the same path.
        let destructiveOverrides = userDataRemovalOverrides
        scannerSelection.subtract(destructiveOverrides)
        userDataRemovalOverrides.removeAll()
        isScanning = true
        scanProgress = 0

        let scanID = UUID()
        currentScanID = scanID
        isCancellingScan = false
        scanTask = Task { [weak self] in
            guard let self else { return }
            let presentation = OperationPresentationDuration()
            defer {
                self.isScanning = false
                self.scanTask = nil
                self.currentScanID = nil
            }
            do {
                let results = try await scanner.scan(
                    onProgress: { progress in
                        Task { @MainActor in
                            guard self.currentScanID == scanID, !self.isCancellingScan else { return }
                            self.scanProgress = progress.percent
                        }
                    }
                )
                try Task.checkCancellation()
                self.scanResults = results
                self.lastScanFinishedAt = results.finishedAt
                defaults.set(results.finishedAt, forKey: "lastScanFinishedAt")
                // Fresh results arrive collapsed. Closed rows form a short summary
                // the user can take in at a glance, and opening one is a click.
                self.openCategories = []
                // Here, because a scan finishing is what arms the selection. It
                // used to be a `.task` on the "Safe to Remove" tab's summary, so
                // nothing was ticked until the user happened to visit that tab —
                // and the Remove button, which reads the same selection, stayed
                // dead on the tab the scan actually lands on.
                self.seedSafeToRemoveSelection()
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                guard !Task.isCancelled else { return }
                self.onFailure?(
                    "The Scan Did Not Finish",
                    "Scolo could not finish measuring. Nothing was removed; try scanning again."
                )
            }
            try? await presentation.wait()
        }
    }

    func cancelScan() {
        isCancellingScan = true
        scanTask?.cancel()
    }

    private var hasStartedInitialCleanupScan = false
}
