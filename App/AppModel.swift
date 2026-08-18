import SwiftUI
import AppKit
import Observation
import MacCleanerCore

/// The design's `State Management` block, as one observable object.
///
/// Everything derivable is a computed property, never stored — the handoff lists
/// selected totals, item counts, the Clean Up label and the enabled state of Clean Up
/// as "Derived, never stored". Storing them is how they drift out of sync with the
/// selection that produced them.
@MainActor
@Observable
final class AppModel {

    enum View: String, CaseIterable, Identifiable {
        case dashboard, scanner, large, trash
        // Reached from the Dashboard tiles, not the sidebar. Back returns.
        case safeToRemove, needsReview
        var id: String { rawValue }

        /// The sidebar's rows. The tile views stay out: they are drill-downs from
        /// the Dashboard, and listing them as siblings would make four views six.
        static var sidebarCases: [View] { [.dashboard, .scanner, .large, .trash] }

        var title: String {
            switch self {
            case .dashboard:    "Dashboard"
            case .scanner:      "Scanner"
            case .large:        "Large & Old Files"
            case .trash:        "Trash"
            case .safeToRemove: "Safe to Remove"
            case .needsReview:  "Needs Review"
            }
        }

        /// SF Symbols, per the design's icon table.
        var symbol: String {
            switch self {
            case .dashboard:    "speedometer"
            case .scanner:      "magnifyingglass"
            case .large:        "folder"
            case .trash:        "trash"
            case .safeToRemove: "checkmark.shield"
            case .needsReview:  "questionmark.folder"
            }
        }
    }

    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash
        var id: String { rawValue }
    }

    // MARK: - Navigation

    var view: View = .dashboard {
        didSet {
            guard view != oldValue else { return }
            history.append(oldValue)
            forwardStack.removeAll()
        }
    }
    private var history: [View] = []
    private var forwardStack: [View] = []

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = history.popLast() else { return }
        forwardStack.append(view)
        withoutHistory { view = previous }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        history.append(view)
        withoutHistory { view = next }
    }

    private func withoutHistory(_ change: () -> Void) {
        let savedHistory = history
        let savedForward = forwardStack
        change()
        history = savedHistory
        forwardStack = savedForward
    }

    // MARK: - Data

    var volume: VolumeInfo?
    var breakdown: StorageBreakdown?
    var snapshots: [SnapshotInfo] = []
    var scanResults: ScanResults?

    var isLoadingBreakdown = false
    var isScanning = false
    var scanProgress = 0

    var snapshotsExpanded = false
    var openCategories: Set<CategoryID> = [.documentsAndFiles]

    // MARK: - Selection
    //
    // Scanner and Large Files feed one shared pool, so the Clean Up total spans both.

    var scannerSelection: Set<FileEntry.ID> = []
    var largeFilesSelection: Set<FileEntry.ID> = []
    var activeSheet: Sheet?

    var statusMessage: String = "Ready to scan"

    // MARK: - Derived

    var allEntries: [FileEntry] {
        let tops = scanResults?.categories.flatMap(\.entries) ?? []
        // Children are selectable in their own right (removing an app's cache while
        // keeping the app), so they must resolve from the selection set too. A
        // selected parent strips its children from the set, so nothing double-counts.
        return tops + tops.flatMap(\.children)
    }

    var selectedEntries: [FileEntry] {
        let selected = scannerSelection.union(largeFilesSelection)
        return allEntries.filter { selected.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedEntries.reduce(0) { $0 + $1.totalBytesIncludingChildren }
    }

    var hasSelection: Bool { !scannerSelection.isEmpty || !largeFilesSelection.isEmpty }

    /// `Clean Up 4.2 GB` when something is selected, plain `Clean Up` otherwise.
    var cleanUpLabel: String {
        hasSelection ? "Clean Up \(ByteFormatting.string(selectedBytes))" : "Clean Up"
    }

    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }
    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }

    func selectedBytes(in category: CategoryID) -> Int64 {
        guard let entries = scanResults?.categories.first(where: { $0.categoryID == category })?.entries
        else { return 0 }
        return entries.reduce(Int64(0)) { total, entry in
            if scannerSelection.contains(entry.id) {
                return total + entry.totalBytesIncludingChildren
            }
            // Individually selected children count toward their category's readout.
            return total + entry.children
                .filter { scannerSelection.contains($0.id) }
                .reduce(0) { $0 + $1.allocatedBytes }
        }
    }

    /// Drops entries whose files no longer exist.
    ///
    /// The scan table is a snapshot, and the world changes under it: the user
    /// deletes an app in Finder, empties the Trash, a build regenerates. A stale
    /// row keeps its old size against a path that is gone, and renders with the
    /// generic missing-file icon: a 3.69 GB "empty file" that does not exist.
    func pruneVanishedEntries() {
        guard var results = scanResults else { return }
        let fileManager = FileManager.default
        var vanished: Set<FileEntry.ID> = []

        results.categories = results.categories.map { category in
            var copy = category
            copy.entries.removeAll { entry in
                // Synthetic rows (Docker's accounting, manual-removal aggregates)
                // keep their place; only real paths are checked.
                guard entry.url.isFileURL, entry.manualRemoval == nil else { return false }
                let gone = !fileManager.fileExists(atPath: entry.url.path)
                if gone { vanished.insert(entry.id) }
                return gone
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
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.reclaimableBytes }
            return copy
        }

        if !vanished.isEmpty {
            scanResults = results
            scannerSelection.subtract(vanished)
            largeFilesSelection.subtract(vanished)
        }
    }

    func deselectAll() {
        scannerSelection.removeAll()
        largeFilesSelection.removeAll()
    }

    /// Kept on for the receipt checkbox in the clean-up sheet.
    var keepReceipt = true

    // MARK: - Removal

    private let cleanupService = CleanupService()

    /// Performs the clean-up the sheet just confirmed.
    ///
    /// Freed bytes come from `CleanupOutcome`, measured immediately before each
    /// removal — never from the selection total, which would report what we *hoped*
    /// to free rather than what actually went.
    func performCleanUp() async {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        activeSheet = nil

        let outcome = (try? await cleanupService.remove(
            entries: entries,
            trashFirst: true,
            // Root-owned App Store installs (iMovie) need Finder's own remedy: one
            // admin prompt. Only the app opts into it; headless callers never can.
            privilegedFallback: true
        )) ?? CleanupOutcome(freedBytes: 0, removedCount: 0, failed: entries.map(\.id))

        deselectAll()
        // Removed entries must leave the tables, or the next total counts files that
        // are already gone.
        if var results = scanResults {
            let removed = Set(entries.map(\.id)).subtracting(Set(outcome.failed))
            results.categories = results.categories.map { category in
                var copy = category
                copy.entries.removeAll { removed.contains($0.id) }
                // Individually removed children leave their parent's disclosure too.
                copy.entries = copy.entries.map { entry in
                    var entry = entry
                    entry.children.removeAll { removed.contains($0.id) }
                    return entry
                }
                copy.totalBytes = copy.entries.reduce(0) { $0 + $1.reclaimableBytes }
                return copy
            }
            scanResults = results
        }

        statusMessage = Self.cleanUpStatus(outcome)
        // The disk changed, so the cached breakdown is now wrong.
        await measureStorage()
        await loadTrash()
    }

    private static func cleanUpStatus(_ outcome: CleanupOutcome) -> String {
        var message = "Moved \(ByteFormatting.string(outcome.freedBytes)) to the Trash."
        if outcome.removedCount > 0 { message += " You can undo for 30 days." }
        if !outcome.failed.isEmpty {
            // Silent partial failure is how a cleaner loses trust.
            let noun = outcome.failed.count == 1 ? "item" : "items"
            message += " \(outcome.failed.count) \(noun) could not be removed."
        }
        return message
    }

    // MARK: - Trash

    private let trashService = TrashService()
    var trashSummary: TrashSummary?

    func loadTrash() async {
        // Everything, largest first. The list is lazy, so row count costs nothing,
        // and a Trash screen that hides items reads as missing files. (The design
        // mock's "showing the 4 largest" was sample data, not a principle.)
        trashSummary = try? await trashService.summary(limit: Int.max)
    }

    /// Last measured size per category, for the Preferences › Categories rows.
    /// Absent until a scan has run — those rows show an em dash rather than `0 B`,
    /// which would claim a measurement that never happened.
    var categorySizes: [CategoryID: Int64] {
        guard let results = scanResults else { return [:] }
        return Dictionary(uniqueKeysWithValues: results.categories.map { ($0.categoryID, $0.totalBytes) })
    }

    func emptyTrash() async {
        activeSheet = nil
        do {
            let result = try await trashService.empty(privilegedFallback: true)
            var message = "Emptied the Trash. Reclaimed \(ByteFormatting.string(result.freedBytes))."
            if result.skipped > 0 {
                let noun = result.skipped == 1 ? "item" : "items"
                message += " \(result.skipped) \(noun) could not be removed."
            }
            statusMessage = message
            view = .dashboard
        } catch {
            // Do not pretend. The denied read stays on the Trash screen with the
            // remedy named.
            statusMessage = "The Trash could not be read. Grant Full Disk Access "
                + "in System Settings, Privacy & Security."
        }
        await loadTrash()
        await measureStorage()
    }

    func putBack(_ item: TrashItem) async {
        try? await trashService.putBack(item)
        await loadTrash()
    }

    // MARK: - Loading

    private let diskInfo = DiskInfoService()
    private let snapshotService = SnapshotService()
    private let breakdownService = StorageBreakdownService()
    private let coordinator = ScanCoordinator.standard()
    private var scanTask: Task<Void, Never>?

    /// Last measured figures, shown immediately on launch.
    private(set) var measuredAt: Date?
    var breakdownIsStale: Bool {
        guard let measuredAt else { return true }
        return Date().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }

    /// Loads the Dashboard without touching the disk unless it has to.
    ///
    /// Measuring walks `~/Documents`, `~/Desktop` and `~/Downloads`, all of which
    /// macOS gates behind TCC. Doing that on every launch meant a permission prompt
    /// on every launch. Cached figures are shown instead, and a measurement runs only
    /// when there is nothing cached or the user asks for one.
    func loadDashboard() async {
        if let cached = BreakdownCache.load() {
            volume = cached.volume
            breakdown = cached.breakdown
            measuredAt = cached.measuredAt
        }

        // Cheap and never gated by TCC: `diskutil` reads volume totals, and snapshot
        // listing touches no user files. Both are safe on every launch.
        volume = (try? await diskInfo.volumeInfo()) ?? volume
        snapshots = (try? await snapshotService.listAll()) ?? []

        if breakdown == nil {
            await measureStorage()
        }
    }

    /// Walks the disk. Only ever called deliberately.
    func measureStorage() async {
        guard !isLoadingBreakdown else { return }
        isLoadingBreakdown = true
        defer { isLoadingBreakdown = false }

        guard let measured = try? await breakdownService.breakdown() else { return }
        breakdown = measured
        measuredAt = Date()

        if let volume {
            BreakdownCache(volume: volume, breakdown: measured, measuredAt: Date()).save()
        }
    }

    /// Re-entrancy is the coordinator's job; this only drives the UI state.
    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        view = .scanner

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanning = false
                self.scanTask = nil
            }
            do {
                // Ground truth for app protection: what is running right now.
                // NSWorkspace is AppKit, so the set is built here and handed to Core.
                let running = Set(
                    NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
                )
                let results = try await coordinator.scan(
                    context: ScanContext(runningApplicationPaths: running),
                    onProgress: { progress in
                        Task { @MainActor in self.scanProgress = progress.percent }
                    }
                )
                self.scanResults = results
                // Fresh results arrive collapsed: seven closed rows are a summary
                // the user can take in at a glance, and opening one is a click.
                self.openCategories = []
                self.statusMessage = "Scan complete. Found "
                    + "\(ByteFormatting.string(results.totalBytes)) in "
                    + "\(results.actionableCategories.count) categories."
                // The scan itself is over — say so before the breakdown refresh, or
                // the toolbar sits at "Measuring 100%" looking wedged while the
                // Dashboard's cache rebuilds behind it.
                self.isScanning = false
                // A scan has already paid the traversal cost and any permission
                // prompts, so refresh the cached breakdown while we are here.
                await self.measureStorage()
            } catch is CancellationError {
                self.statusMessage = "Scan cancelled"
            } catch {
                self.statusMessage = "Scan failed"
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        Task { await coordinator.cancel() }
    }
}
