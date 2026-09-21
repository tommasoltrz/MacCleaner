import SwiftUI
import AppKit
import CoreGraphics
import IOKit.ps
import Observation
import ScoloCore

/// The design's `State Management` block, as one observable object.
///
/// Everything derivable is a computed property, never stored — the handoff lists
/// selected totals, item counts, the Clean Up label and the enabled state of Clean Up
/// as "Derived, never stored". Storing them is how they drift out of sync with the
/// selection that produced them.
@MainActor
@Observable
final class AppModel {

    /// The preferences the engine must obey. Injected at launch; optional only so
    /// previews and tests can build a model without a store.
    @ObservationIgnored var settings: SettingsStore?
    let storageExplorer: StorageExplorerModel

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        self.storageExplorer = StorageExplorerModel(settings: settings)
        startScheduler()
    }

    // MARK: - Automatic scanning

    /// The scheduler checks the scan schedule and the free-space threshold at this
    /// interval. Most idle-only checks decline. A later check starts the due scan.
    /// The volume check also finds low-space crossings caused by other apps.
    private static let schedulerTick: Duration = .seconds(300)
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    /// Drives Preferences › General › "Scan automatically", which until now was
    /// persisted, displayed, and consulted by nothing at all.
    private func startScheduler() {
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.schedulerTick)
                guard let self, !Task.isCancelled else { return }
                await self.refreshVolumeInfo()
                if self.scheduledScanIsDue() {
                    // Automatic: the view does not jump to the Scanner under
                    // whatever the user was reading.
                    self.startScan(automatic: true)
                }
            }
        }
    }

    /// Gathers the live inputs; ``AutomaticScanPolicy`` makes the decision, where
    /// `swift test` can reach it.
    func scheduledScanIsDue() -> Bool {
        guard let settings else { return false }
        return AutomaticScanPolicy.isDue(AutomaticScanPolicy.Conditions(
            now: Date(),
            lastFinished: lastScanFinishedAt,
            cadence: settings.scanSchedule.cadence,
            requiresIdleAndPower: settings.idleOnly,
            isOnACPower: Self.isOnACPower,
            secondsSinceUserInput: Self.secondsSinceUserInput,
            isScanning: isScanning
        ))
    }

    /// "Plugged in", as the setting words it. A desktop with no battery reports AC
    /// and qualifies, which is the right answer for it.
    ///
    /// `IOPSGetProvidingPowerSourceType` reads a snapshot; passing `nil` asked it to
    /// describe nothing. And it is a *Get*, so the string it returns is not owned by
    /// the caller — only the snapshot from the *Copy* is.
    private static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        // `kIOPSACPowerValue`, spelled out: the constant is not bridged into Swift.
        return (source as String) == "AC Power"
    }

    /// Seconds since the last keyboard or mouse event anywhere in the session.
    private static var secondsSinceUserInput: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    enum View: String, CaseIterable, Identifiable {
        case dashboard, scanner, storageExplorer, uninstaller, history, trash, duplicates
        var id: String { rawValue }

        /// The sidebar's rows. Destructive workflows sit at the end: review an
        /// application's complete uninstall first, then the Trash where removed
        /// items ultimately land.
        static var sidebarCases: [View] {
            [.dashboard, .scanner, .storageExplorer, .duplicates, .uninstaller, .history, .trash]
        }

        var title: String {
            switch self {
            case .dashboard:    "Dashboard"
            case .scanner:      "Scanner"
            case .storageExplorer: "Storage Explorer"
            case .uninstaller:  "App Uninstaller"
            case .history:      "History"
            case .trash:        "Trash"
            case .duplicates:   "Duplicates"
            }
        }

        /// SF Symbols, per the design's icon table.
        var symbol: String {
            switch self {
            case .dashboard:    "speedometer"
            case .scanner:      "magnifyingglass"
            case .storageExplorer: "externaldrive"
            case .uninstaller:  "xmark.app"
            case .history:      "clock.arrow.circlepath"
            case .trash:        "trash"
            case .duplicates:   "square.on.square"
            }
        }
    }

    /// Which part of the scan the Scanner is showing.
    ///
    /// Safe to Remove and Needs Review used to be views of their own, reached from
    /// the Dashboard tiles and from nowhere else. A scan lands on the Scanner, so
    /// the scan's conclusion — what regenerates, what wants a decision — has to be
    /// readable there; asking the user to go back to the Dashboard for it was
    /// asking them to leave the page the scan had just put them on.
    ///
    /// The filter narrows the list and nothing else. The composition bar above it
    /// keeps describing the whole scan, whichever lens is chosen.
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

    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash, deleteDuplicateFiles, deletePhotos, removeStorageItems, uninstallApp,
             uninstallApps
        var id: String { rawValue }
    }

    enum DuplicateKind: String, CaseIterable, Identifiable {
        case files, photos
        var id: String { rawValue }

        var title: String {
            switch self {
            case .files:  "Files"
            case .photos: "Photos"
            }
        }
    }

    // MARK: - Navigation

    var view: View = .dashboard {
        didSet {
            guard view != oldValue else { return }
            history.append(oldValue)
            forwardStack.removeAll()
        }
    }
    var duplicateKind: DuplicateKind = .files

    /// Edit › Find (⌘F) bumps this; the view on screen moves focus to its search
    /// field when it changes. A counter and not a flag, so a second ⌘F after the
    /// user has clicked away focuses again with nothing to reset in between.
    private(set) var findRequest = 0

    /// The views with a list to search. Find is disabled everywhere else, not left
    /// as a key that does nothing.
    var canFind: Bool {
        switch view {
        case .trash, .history, .uninstaller: activity == nil
        case .dashboard, .scanner, .storageExplorer, .duplicates: false
        }
    }

    func requestFind() {
        guard canFind else { return }
        findRequest += 1
    }

    var scanFilter: ScanFilter = .all
    private var history: [View] = []
    private var forwardStack: [View] = []

    var canGoBack: Bool {
        if view == .storageExplorer, storageExplorer.canGoBack {
            return !isStorageExplorerMeasurementBlocked
        }
        return !history.isEmpty
    }
    var canGoForward: Bool {
        if view == .storageExplorer, storageExplorer.canGoForward {
            return !isStorageExplorerMeasurementBlocked
        }
        return !forwardStack.isEmpty
    }

    func goBack() {
        if view == .storageExplorer, storageExplorer.canGoBack {
            guard !isStorageExplorerMeasurementBlocked else { return }
            storageExplorer.goBack()
            return
        }
        guard let previous = history.popLast() else { return }
        forwardStack.append(view)
        withoutHistory { view = previous }
    }

    func goForward() {
        if view == .storageExplorer, storageExplorer.canGoForward {
            guard !isStorageExplorerMeasurementBlocked else { return }
            storageExplorer.goForward()
            return
        }
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

    /// When the last junk scan finished, surviving relaunch. The results themselves
    /// are recomputed on demand — cheap to re-earn, dangerous to trust stale — but
    /// "when did I last scan" is an answer the Dashboard should always have.
    private(set) var lastScanFinishedAt: Date? =
        UserDefaults.standard.object(forKey: "lastScanFinishedAt") as? Date

    var isLoadingBreakdown = false
    /// The first Dashboard task has finished its complete refresh. Cached figures
    /// may be restored before then, but they are only inputs to that refresh — not a
    /// finished state to flash on screen for a moment before measurement begins.
    private(set) var hasCompletedInitialDashboardLoad = false
    var isDashboardLoading: Bool {
        !hasCompletedInitialDashboardLoad || isLoadingBreakdown
    }
    var isScanning = false
    var scanProgress = 0

    var snapshotsExpanded = false
    var openCategories: Set<CategoryID> = [.documentsAndFiles]

    // MARK: - Selection

    var scannerSelection: Set<FileEntry.ID> = []
    /// User-data rows whose lock the user explicitly opened for this selection.
    /// Kept separate from the selection itself so neither a stale ID nor a bulk
    /// selection can silently acquire the override.
    var userDataRemovalOverrides: Set<FileEntry.ID> = []
    var activeSheet: Sheet?

    /// What is left to say when an operation did not simply do what it said.
    ///
    /// Two kinds of thing reach here: a failure or a partial failure, and a
    /// success that leaves the user something to do somewhere else — deleting
    /// photos frees nothing until Recently Deleted is emptied in Photos, and no
    /// part of this app could say so.
    ///
    /// Until 21 Sep 2026 all of these were a line in the window's footer, next to
    /// the ordinary reports of things going right. That made a failure look
    /// exactly like a success, and the next operation overwrote it before it had
    /// been read. The footer is gone, and the plain successes went with it: each
    /// view shows its own result — rows leave the list, figures change, a done
    /// page says what it did. What is here cannot show itself that way, so it
    /// waits to be dismissed.
    ///
    /// Never a cancellation: the user stopped it and knows.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    var notice: Notice?

    func report(_ title: String, _ message: String) {
        notice = Notice(title: title, message: message)
    }

    /// The disk operation in progress, if any. The window is covered while it
    /// runs. See `ActivityOverlay`.
    ///
    /// Cleared before the post-removal refresh. That disk walk has its own page
    /// state. Keeping the scrim visible made the cleanup appear frozen.
    private(set) var activity: Activity?

    enum Activity: Equatable {
        case cleaningUp(itemCount: Int, totalBytes: Int64)
        case emptyingTrash(itemCount: Int, totalBytes: Int64)
        case removingDuplicateFiles(itemCount: Int, totalBytes: Int64)
        case removingStorageItems(itemCount: Int, totalBytes: Int64)
        case reviewingStorageItems(itemCount: Int)
        case uninstalling(applicationName: String, applicationOnly: Bool, waitingToQuit: Bool)
        case waitingForApplicationsToQuit(names: [String])

        var title: String {
            switch self {
            case .cleaningUp(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .emptyingTrash:
                return "Emptying the Trash"
            case .removingDuplicateFiles(let count, _):
                let files = count == 1 ? "file" : "files"
                return "Moving \(count) duplicate \(files) to the Trash"
            case .removingStorageItems(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .reviewingStorageItems(let count):
                let items = count == 1 ? "item" : "items"
                return "Reviewing \(count) \(items)"
            case .uninstalling(let name, _, let waiting):
                return waiting ? "Waiting for \(name) to quit" : "Uninstalling \(name)"
            case .waitingForApplicationsToQuit(let names):
                return "Waiting for \(ListFormatter.localizedString(byJoining: names)) to quit"
            }
        }

        /// Explains why the current disk operation can take time.
        var detail: String {
            switch self {
            case .cleaningUp(_, let bytes),
                 .emptyingTrash(_, let bytes),
                 .removingStorageItems(_, let bytes):
                return "\(ByteFormatting.string(bytes)). Each item is measured on disk "
                    + "before it goes, so large folders take a moment."
            case .removingDuplicateFiles(_, let bytes):
                // Not measured: re-hashed. The keeper and every chosen copy are read
                // in full again, which is what makes a set of large videos slow.
                return "\(ByteFormatting.string(bytes)). Each copy and its keeper are "
                    + "verified byte for byte before it goes, so large files take a moment."
            case .waitingForApplicationsToQuit:
                return "Each application is asked to quit, never forced — answer any "
                    + "save prompt it shows. Nothing is removed until they are gone."
            case .reviewingStorageItems:
                return "Scolo is updating each size and checking each item before confirmation."
            case .uninstalling(_, let applicationOnly, let waiting):
                if waiting {
                    return "The application and its helpers are asked to quit. "
                        + "Nothing is removed until they are gone."
                }
                return applicationOnly
                    ? "Related files stay on disk."
                    : "The application moves first. Related data stays if that move fails."
            }
        }
    }

    var isCleaningUp: Bool {
        if case .cleaningUp? = activity { return true }
        return false
    }
    var isUninstallingApp: Bool {
        if case .uninstalling? = activity { return true }
        return false
    }
    var isRemovingDuplicateFiles: Bool {
        if case .removingDuplicateFiles? = activity { return true }
        return false
    }
    var isRemovingStorageItems: Bool {
        if case .removingStorageItems? = activity { return true }
        return false
    }
    var isShowingAppDataAccessAlert = false

    var isStorageExplorerMeasurementBlocked: Bool {
        isScanning || isScanningDuplicateFiles || isSweepingPhotos || activity != nil
    }

    /// One disk walk at a time. A junk scan, a duplicate scan, a photo sweep, an
    /// Explorer measurement and a removal all contend for the same disk, and each
    /// start guard refuses silently — so the buttons that would start one read this
    /// and disable themselves, rather than clicking to no effect.
    var isBusyWithDisk: Bool {
        isScanning || isScanningDuplicateFiles || isSweepingPhotos
            || storageExplorer.isLoading || activity != nil
    }

    private(set) var pendingStorageExplorerItems: [StorageExplorerItem] = []

    var storageExplorerSelectionLabel: String {
        let count = storageExplorer.selectedItems.count
        guard count > 0 else { return "Move to Trash" }
        return "Move \(count) \(count == 1 ? "Item" : "Items") to Trash"
    }

    func requestStorageExplorerRemoval() async {
        guard storageExplorer.canRemoveSelection, !isBusyWithDisk else { return }
        let selectedItems = storageExplorer.selectedItems
        activity = .reviewingStorageItems(itemCount: selectedItems.count)

        do {
            let review = try await storageExplorer.reviewSelectionForRemoval(selectedItems)
            activity = nil
            guard let review else { return }
            // A refusal has to say so. Pressing the button and getting no sheet,
            // no message and a quietly rewritten list is indistinguishable from a
            // button that does not work.
            guard review.isReady else {
                if !review.changedPaths.isEmpty {
                    report(
                        "The Selection Changed",
                        "Some of those items are not what they were when you picked them. "
                            + "Review the updated list and try again."
                    )
                } else if !review.protectedPaths.isEmpty {
                    report(
                        "Some Items Are Protected",
                        "Scolo will not remove some of the selected items. "
                            + "Review the list and try again."
                    )
                } else {
                    // The third way a review is not ready: nothing selected is
                    // still there to remove.
                    report(
                        "Nothing Left to Remove",
                        "The selected items are no longer in this folder."
                    )
                }
                return
            }
            pendingStorageExplorerItems = review.items
            activeSheet = .removeStorageItems
        } catch is CancellationError {
            activity = nil
        } catch {
            activity = nil
            report(
                "The Selection Could Not Be Checked",
                "Scolo re-reads every selected item before it offers to remove anything, "
                    + "and this time it could not. Nothing was removed."
            )
        }
    }

    func cancelStorageExplorerRemoval() {
        pendingStorageExplorerItems.removeAll()
        activeSheet = nil
    }

    func performStorageExplorerRemoval() async {
        let items = pendingStorageExplorerItems
        guard !items.isEmpty, activity == nil else { return }
        pendingStorageExplorerItems.removeAll()
        activeSheet = nil
        activity = .removingStorageItems(
            itemCount: items.count,
            totalBytes: items.reduce(0) { $0 + $1.allocatedBytes }
        )

        do {
            let outcome = try await storageExplorer.remove(items, keepReceipt: keepReceipt)
            // Success needs no announcement: the rows are gone from the folder the
            // user is looking at, which is the measurement being redone below.
            if !outcome.failed.isEmpty {
                let count = outcome.failed.count
                report(
                    outcome.removedCount == 0
                        ? "Nothing Was Removed" : "Some Items Could Not Be Moved",
                    "\(count) \(count == 1 ? "item" : "items") could not move to the Trash. "
                        + "\(outcome.removedCount) of \(items.count) did."
                )
            }
        } catch is CancellationError {
            // The user stopped it.
        } catch {
            report(
                "The Items Could Not Be Moved",
                "The selected items could not move to the Trash. Nothing was removed."
            )
        }

        activity = nil
        storageExplorer.refresh(clearAllCachedFolders: true)
        await refreshAfterRemoval()
    }

    // MARK: - Derived

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

    private var selectedOrphanApplicationEntries: [FileEntry] {
        let selected = scannerSelection
        return scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .entries.filter { selected.contains($0.id) } ?? []
    }

    private var selectedOrphanBundleIdentifiersFromScanner: Set<String> {
        Set(selectedOrphanApplicationEntries.compactMap(\.orphanedApplicationBundleIdentifier))
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

    /// `Clean Up 4.2 GB` when something is selected, plain `Clean Up` otherwise.
    var cleanUpLabel: String {
        hasSelection ? "Clean Up \(ByteFormatting.string(selectedBytes))" : "Clean Up"
    }

    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }
    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }

    func selectedBytes(in category: CategoryID) -> Int64 {
        guard let entries = scanResults?.categories.first(where: { $0.categoryID == category })?.entries
        else { return 0 }
        if category == .applicationLeftovers {
            return entries
                .filter { scannerSelection.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
        }
        return entries.reduce(Int64(0)) { total, entry in
            if scannerSelection.contains(entry.id) {
                let targets = plannedTargets(for: entry)
                let covered = Set(targets.map(\.id))
                // A protected child may be unlocked individually after selecting
                // “keep data” for its parent. It is not covered by the parent's
                // plan, so count that explicit child selection too.
                let extraChildren = entry.children
                    .filter { scannerSelection.contains($0.id) && !covered.contains($0.id) }
                    .reduce(0) { $0 + plannedBytes(for: $1) }
                return total + targets.reduce(0) { $0 + $1.allocatedBytes } + extraChildren
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

    /// The rows behind a Dashboard tile — the same arithmetic the tile summed, so
    /// the list and the figure above it can never disagree.
    ///
    /// Judged per entry, not per category: a non-regenerable row inside a safe
    /// category (an `.xcarchive`) belongs to "Needs review", whatever badge its
    /// category wears. Deduplicated by path, because an entry two categories both
    /// claim is one thing to remove, not two.
    /// The rows behind a Dashboard tile.
    ///
    /// The split itself is `ScanCategoryResult.tileRows`, in Core beside the two
    /// figures the tiles print, so the number and the list it opens cannot come apart.
    /// This adds only what is view-level: one appearance per row across categories,
    /// and the order the table draws.
    func tileEntries(safeToRemove wantSafe: Bool) -> [FileEntry] {
        guard let results = scanResults else { return [] }
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .flatMap { $0.tileRows(safeToRemove: wantSafe) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayBytes > $1.displayBytes }
    }

    /// Opens the Scanner on one of its filtered lists.
    ///
    /// The order matters: the filter is set before the view, so the Scanner draws
    /// the requested list on its first frame instead of showing the whole outline
    /// for a frame and then replacing it.
    func showScanner(filtered filter: ScanFilter) {
        scanFilter = filter
        view = .scanner
    }

    /// Rows in the filtered list whose checkbox actually works. A locked entry — a
    /// running app, user data, a manual-removal aggregate — must never be swept into
    /// a total that would then fail at cleanup.
    ///
    /// Empty under `.all`: that list is grouped by category with its own per-category
    /// controls, and a sweep across every category at once is not something the
    /// Scanner offers.
    private var selectableInCurrentView: [FileEntry] {
        switch scanFilter {
        case .all:
            []
        case .safeToRemove:
            tileEntries(safeToRemove: true).filter {
                !$0.isRemovalLocked && $0.kind != .appBundle
            }
        case .needsReview:
            tileEntries(safeToRemove: false).filter {
                !$0.isRemovalLocked && $0.kind != .appBundle
            }
        }
    }

    /// Whether the current view offers a Select All at all, and whether it would
    /// change anything.
    var canSelectAllInCurrentView: Bool {
        let selectable = selectableInCurrentView
        return !selectable.isEmpty
            && !selectable.allSatisfy { scannerSelection.contains($0.id) }
    }

    /// The scan whose Safe to Remove list has already been pre-selected, so the
    /// seeding happens once per scan and never fights the user afterwards.
    @ObservationIgnored private var safeSelectionSeededAt: Date?

    /// Ticks everything in the Safe to Remove list the moment it is shown.
    ///
    /// This list contains regenerable data and verified application leftovers.
    /// Locked rows stay clear of the selection, and Clean Up still asks for
    /// confirmation. Needs Review starts with no selection because the user must
    /// make that decision.
    ///
    /// Seeded once per scan. Re-seeding on every appearance would undo a
    /// deliberate deselection the moment the user stepped away and came back; a new
    /// scan is a new list, so it re-arms.
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

    /// Selects every selectable row in the current drill-down.
    ///
    /// Selecting a parent strips individual children from the pool — the same rule
    /// the table applies row by row — so the sweep never counts a byte twice.
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

    // MARK: - App uninstaller

    private let appUninstallPlanner = AppUninstallPlanner()
    private let orphanedAppLeftoverPlanner = OrphanedAppLeftoverPlanner()
    @ObservationIgnored private var appUninstallTask: Task<Void, Never>?
    @ObservationIgnored private var appUninstallPlanningID: UUID?

    var appUninstallPlan: AppUninstallPlan?
    var isPlanningAppUninstall = false
    /// The one application being planned, so its review can draw its header before
    /// the plan exists. Nil while several are planned in turn.
    private(set) var appUninstallPlanningURL: URL?
    var appUninstallError: String?
    var appUninstallOutcome: CleanupOutcome?
    var lastUninstalledApplicationName: String?

    struct PendingAppUninstall {
        let plan: AppUninstallPlan

        var itemCount: Int { plan.items.count }
        var totalBytes: Int64 { plan.totalBytes }
        var protectedDataCount: Int { plan.protectedItems.count }
        var isApplicationOnly: Bool { plan.isApplicationOnly }
    }

    private(set) var pendingAppUninstall: PendingAppUninstall?

    /// Opens the dedicated review for an installed application. Called by the
    /// Uninstaller's picker/drop target and by “Uninstall App…” on scanner rows.
    func planAppUninstall(_ applicationURL: URL) {
        appUninstallTask?.cancel()
        appUninstallPlan = nil
        appUninstallOutcome = nil
        lastUninstalledApplicationName = nil
        appUninstallError = nil
        appUninstallPlanningDetail = nil
        batchUninstallReview = nil
        batchUninstallOutcome = nil
        isPlanningAppUninstall = true
        appUninstallPlanningURL = applicationURL.standardizedFileURL
        view = .uninstaller
        let planningID = UUID()
        appUninstallPlanningID = planningID

        let settings = settings
        let context = ScanContext(
            // Uninstall candidates must always be the paths themselves. Following a
            // symlink would measure bytes that unlinking the candidate cannot free.
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        let planner = appUninstallPlanner
        appUninstallTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.appUninstallPlanningID == planningID {
                    self.isPlanningAppUninstall = false
                    self.appUninstallPlanningURL = nil
                    self.appUninstallTask = nil
                    self.appUninstallPlanningID = nil
                }
            }
            do {
                let plan = try await planner.plan(
                    applicationURL: applicationURL, context: context
                )
                try Task.checkCancellation()
                self.appUninstallPlan = plan
            } catch is CancellationError {
                return
            } catch {
                // Shown on the review page itself, where the user is waiting.
                self.appUninstallError = error.localizedDescription
            }
        }
    }

    func resetAppUninstall() {
        guard !isUninstallingApp else { return }
        appUninstallTask?.cancel()
        appUninstallTask = nil
        appUninstallPlanningID = nil
        appUninstallPlan = nil
        appUninstallError = nil
        appUninstallOutcome = nil
        lastUninstalledApplicationName = nil
        pendingAppUninstall = nil
        isPlanningAppUninstall = false
        appUninstallPlanningURL = nil
        appUninstallPlanningDetail = nil
        batchUninstallReview = nil
        batchUninstallOutcome = nil
        pendingBatchUninstall = nil
    }

    // MARK: Installed applications

    /// What the Uninstaller opens on. `nil` until the folders have been read, so the
    /// page shows nothing rather than "no applications" before it has looked.
    private(set) var installedApplications: [InstalledApplication]?

    /// Bundle sizes by path, filled in as each is measured. An application missing
    /// from here has not been measured yet — its card shows a bone, never a zero.
    /// Kept across visits: a bundle changes when the app updates, and the review
    /// measures it again before anything is promised.
    private(set) var installedApplicationBytes: [String: Int64] = [:]

    /// True once every listed application has been given its chance to be measured.
    /// The grid sorts by size only then: sorting on figures as they arrive moved a
    /// card every time one landed, for as long as the measuring took.
    private(set) var installedApplicationsMeasured = false

    @ObservationIgnored private var installedApplicationsTask: Task<Void, Never>?

    /// Reads the application folders again and measures whatever is new. Listing is
    /// one `contentsOfDirectory` per root plus an Info.plist per app; the sizes are
    /// the slow part (Xcode alone is a few seconds) and arrive one card at a time.
    // MARK: Application leftovers, in the Uninstaller

    /// What removed applications left behind, for the Uninstaller's second tab.
    ///
    /// The Scanner lists these under Needs Review. They are here as well because
    /// this is where the question gets asked: someone who came to uninstall an
    /// application is the person who wants to know what the last one left. `nil`
    /// until it has been looked for, so the tab shows nothing rather than "no
    /// leftovers" before it has looked. It is read from the disk on its own and
    /// needs no junk scan.
    private(set) var applicationLeftovers: OrphanedAppLeftoverPlan?
    private(set) var isLoadingApplicationLeftovers = false
    /// Removed applications ticked in that tab, by bundle identifier.
    var selectedLeftoverIdentifiers: Set<String> = []
    @ObservationIgnored private var applicationLeftoversTask: Task<Void, Never>?

    var selectedLeftoverBytes: Int64 {
        applicationLeftovers?.groups
            .filter { selectedLeftoverIdentifiers.contains($0.bundleIdentifier) }
            .reduce(0) { $0 + $1.totalBytes } ?? 0
    }

    func loadApplicationLeftovers() {
        applicationLeftoversTask?.cancel()
        let settings = settings
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        let planner = orphanedAppLeftoverPlanner
        isLoadingApplicationLeftovers = true
        applicationLeftoversTask = Task { [weak self] in
            // One candidate scan, resolved once, handed to the planner whole — the
            // same order the junk scan uses, for the same reason: scanning twice
            // lets an identifier appear between the passes with no owner check.
            let candidates = await Task.detached(priority: .userInitiated) {
                planner.scanCandidates()
            }.value
            guard self != nil, !Task.isCancelled else { return }
            let registered = Self.registeredApplicationBundleIdentifiers(for: candidates.identifiers)
            let plan = try? await planner.plan(
                context: context,
                registeredApplicationBundleIdentifiers: registered,
                candidates: candidates
            )
            guard let self, !Task.isCancelled else { return }
            self.applicationLeftovers = plan
            self.isLoadingApplicationLeftovers = false
            let listed = Set(plan?.groups.map(\.bundleIdentifier) ?? [])
            self.selectedLeftoverIdentifiers.formIntersection(listed)
        }
    }

    func toggleLeftoverSelection(_ bundleIdentifier: String) {
        if selectedLeftoverIdentifiers.contains(bundleIdentifier) {
            selectedLeftoverIdentifiers.remove(bundleIdentifier)
        } else {
            selectedLeftoverIdentifiers.insert(bundleIdentifier)
        }
    }

    /// Sends the ticked leftovers through the clean-up every other removal takes:
    /// the same captured plan, the same sheet, and
    /// `CleanupService.removeOrphanedAppLeftovers`, which checks each owner and each
    /// file's identity again before anything moves. Nothing here removes a file.
    func requestLeftoverRemoval() {
        guard activity == nil, let leftovers = applicationLeftovers else { return }
        let identifiers = selectedLeftoverIdentifiers
        let items = leftovers.groups
            .filter { identifiers.contains($0.bundleIdentifier) }
            .flatMap(\.items)
        guard !items.isEmpty else { return }
        pendingCleanUp = CleanupPlan(
            entries: [],
            userDataRemovalOverrides: [],
            applicationLeftoverPlan: leftovers,
            orphanedApplicationBundleIdentifiers: identifiers,
            orphanedApplicationItemPaths: Set(items.map(\.id))
        )
        // Always confirmed, whatever the preference says: a leftover is somebody's
        // settings, and this is the only place the user is told how many.
        activeSheet = .cleanUp
    }

    func loadInstalledApplications() {
        installedApplicationsTask?.cancel()
        let settings = settings
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        let planner = appUninstallPlanner
        installedApplicationsTask = Task { [weak self] in
            let applications = await Task.detached(priority: .userInitiated) {
                planner.installedApplications(context: context)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.installedApplications = applications
            let listed = Set(applications.map(\.id))
            self.installedApplicationBytes = self.installedApplicationBytes
                .filter { listed.contains($0.key) }
            self.selectedApplicationIDs.formIntersection(listed)
            self.installedApplicationsMeasured = applications
                .allSatisfy { self.installedApplicationBytes[$0.id] != nil }

            for application in applications
            where self.installedApplicationBytes[application.id] == nil {
                guard !Task.isCancelled else { return }
                // An unreadable bundle stays a bone. The review will say why.
                guard let measurement = try? await context.measurer.measure(application.url)
                else { continue }
                guard !Task.isCancelled else { return }
                self.installedApplicationBytes[application.id] = measurement.allocatedBytes
            }
            self.installedApplicationsMeasured = true
        }
    }

    /// Resolves current application owners through Launch Services. The walk
    /// itself lives in Core and is shared with the CLI; only the oracle is AppKit.
    private static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>
    ) -> Set<String> {
        let fileManager = FileManager.default
        return OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            isInstalled: { identifier in
                guard let application = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: identifier
                ) else { return false }
                return fileManager.fileExists(atPath: application.path)
            }
        )
    }

    func requestAppUninstall() {
        guard let plan = appUninstallPlan, plan.managedPackage == nil else { return }
        pendingAppUninstall = PendingAppUninstall(plan: plan)
        activeSheet = .uninstallApp
    }

    func cancelAppUninstall() {
        pendingAppUninstall = nil
        activeSheet = nil
    }

    private enum UninstallAttempt {
        case stillRunning
        case interrupted
        case finished(CleanupOutcome)
    }

    /// One application, start to finish: ask it to quit, wait, then remove. Shared by
    /// the single review and the batch so both keep the same two promises — nothing
    /// is force-killed, and nothing is removed under a process that is still up.
    private func attemptUninstall(_ plan: AppUninstallPlan) async -> UninstallAttempt {
        let applicationName = plan.applicationName
        let applicationOnly = plan.isApplicationOnly
        activity = .uninstalling(
            applicationName: applicationName, applicationOnly: applicationOnly, waitingToQuit: false
        )

        // Ask the selected app and every helper embedded inside its bundle to quit.
        // Cleanup starts only after they are gone; it never force-kills a process
        // that may still be writing settings.
        let targetPath = plan.applicationURL.standardizedFileURL.path
        func matchingRunningApplications() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { application in
                guard let url = application.bundleURL?.standardizedFileURL else { return false }
                return url.path == targetPath || url.path.hasPrefix(targetPath + "/")
            }
        }
        let running = matchingRunningApplications()
        if !running.isEmpty {
            activity = .uninstalling(
                applicationName: applicationName, applicationOnly: applicationOnly, waitingToQuit: true
            )
            for application in running { application.terminate() }
        }
        for _ in 0..<30 where !matchingRunningApplications().isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !matchingRunningApplications().isEmpty { return .stillRunning }
        activity = .uninstalling(
            applicationName: applicationName, applicationOnly: applicationOnly, waitingToQuit: false
        )

        do {
            return .finished(try await cleanupService.uninstall(
                plan, privilegedFallback: true, keepReceipt: keepReceipt
            ))
        } catch {
            return .interrupted
        }
    }

    func performAppUninstall() async {
        guard let request = pendingAppUninstall, activity == nil else { return }
        pendingAppUninstall = nil
        activeSheet = nil
        appUninstallError = nil
        defer { activity = nil }

        let outcome: CleanupOutcome
        switch await attemptUninstall(request.plan) {
        case .stillRunning:
            appUninstallError = "\(request.plan.applicationName) is still running. "
                + "Quit it and try again; no files were removed."
            return
        case .interrupted:
            appUninstallError = "The uninstall was interrupted. Review the application and try again."
            return
        case .finished(let finished):
            outcome = finished
        }

        appUninstallOutcome = outcome
        lastUninstalledApplicationName = request.plan.applicationName
        appUninstallPlan = nil
        selectedApplicationIDs.remove(request.plan.applicationURL.path)

        let applicationFailed = outcome.failed.contains(request.plan.applicationURL.path)
        if applicationFailed {
            let relatedFilesMessage = request.plan.isApplicationOnly
                ? "" : " No related files were removed."
            appUninstallError = "\(request.plan.applicationName) could not be moved to the Trash."
                + relatedFilesMessage
        }
        // Everything else this used to say is on the done page: what was removed,
        // and how many related items remain on disk.

        pruneVanishedEntries()
        activity = nil
        await refreshAfterRemoval()
    }

    // MARK: Several applications at once

    /// Ticked cards, by path. Survives a trip into one application's review and back.
    private(set) var selectedApplicationIDs: Set<String> = []

    func toggleApplicationSelection(_ application: InstalledApplication) {
        if selectedApplicationIDs.remove(application.id) == nil {
            selectedApplicationIDs.insert(application.id)
        }
    }

    func clearApplicationSelection() { selectedApplicationIDs.removeAll() }

    /// An application the batch will not touch, and why.
    struct SetAsideApplication {
        let name: String
        let reason: String
    }

    /// Every ticked application planned, before anything is asked. A tick is not a
    /// review: the batch still finds each application's related files first and
    /// shows what goes, per application, including how much of it is user data.
    struct BatchUninstallReview {
        let plans: [AppUninstallPlan]
        let setAside: [SetAsideApplication]

        var itemCount: Int { plans.reduce(0) { $0 + $1.items.count } }
        var totalBytes: Int64 { plans.reduce(0) { $0 + $1.totalBytes } }
        var protectedDataCount: Int { plans.reduce(0) { $0 + $1.protectedItems.count } }
    }

    struct BatchUninstallOutcome {
        var uninstalled: [String] = []
        var setAside: [SetAsideApplication] = []
        var removedBytes: Int64 = 0
        var survivorCount = 0
    }

    private(set) var batchUninstallReview: BatchUninstallReview?
    private(set) var batchUninstallOutcome: BatchUninstallOutcome?
    /// "Slack · 2 of 5" under the planning spinner; nil for a single application.
    private(set) var appUninstallPlanningDetail: String?
    /// The plans the sheet was asked about — captured when it opens, like `CleanupPlan`.
    private(set) var pendingBatchUninstall: BatchUninstallReview?

    /// One ticked application is the ordinary review. Several are planned in turn.
    func reviewSelectedApplications() {
        let selected = (installedApplications ?? [])
            .filter { selectedApplicationIDs.contains($0.id) }
        guard !selected.isEmpty, activity == nil else { return }
        if selected.count == 1 {
            planAppUninstall(selected[0].url)
            return
        }

        resetAppUninstall()
        isPlanningAppUninstall = true
        let planningID = UUID()
        appUninstallPlanningID = planningID
        let settings = settings
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        let planner = appUninstallPlanner
        appUninstallTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.appUninstallPlanningID == planningID {
                    self.isPlanningAppUninstall = false
                    self.appUninstallPlanningDetail = nil
                    self.appUninstallTask = nil
                    self.appUninstallPlanningID = nil
                }
            }
            var plans: [AppUninstallPlan] = []
            var setAside: [SetAsideApplication] = []
            for (index, application) in selected.enumerated() {
                guard !Task.isCancelled else { return }
                self.appUninstallPlanningDetail =
                    "\(application.name) · \(index + 1) of \(selected.count)"
                do {
                    let plan = try await planner.plan(
                        applicationURL: application.url, context: context
                    )
                    if let package = plan.managedPackage {
                        // Trashing a cask's bundle leaves Homebrew's receipt behind.
                        // Its own page offers the command; the batch leaves it alone.
                        setAside.append(SetAsideApplication(
                            name: plan.applicationName,
                            reason: "Managed by \(package.manager.rawValue) — open it to copy the uninstall command."
                        ))
                    } else {
                        plans.append(plan)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    setAside.append(SetAsideApplication(
                        name: application.name, reason: error.localizedDescription
                    ))
                }
            }
            guard !Task.isCancelled, self.appUninstallPlanningID == planningID else { return }
            self.batchUninstallReview = BatchUninstallReview(plans: plans, setAside: setAside)
        }
    }

    func requestBatchUninstall() {
        guard let review = batchUninstallReview, !review.plans.isEmpty else { return }
        pendingBatchUninstall = review
        activeSheet = .uninstallApps
    }

    func cancelBatchUninstall() {
        pendingBatchUninstall = nil
        activeSheet = nil
    }

    /// In sequence, each application on its own terms: one that will not quit or will
    /// not move is set aside with its files untouched, and the rest carry on.
    func performBatchUninstall() async {
        guard let request = pendingBatchUninstall, activity == nil else { return }
        pendingBatchUninstall = nil
        activeSheet = nil
        appUninstallError = nil
        defer { activity = nil }

        var result = BatchUninstallOutcome(setAside: request.setAside)
        for plan in request.plans {
            let name = plan.applicationName
            switch await attemptUninstall(plan) {
            case .stillRunning:
                result.setAside.append(SetAsideApplication(
                    name: name, reason: "Still running. No files were removed."
                ))
            case .interrupted:
                result.setAside.append(SetAsideApplication(
                    name: name, reason: "The uninstall was interrupted."
                ))
            case .finished(let outcome):
                result.removedBytes += outcome.removedBytes
                if outcome.failed.contains(plan.applicationURL.path) {
                    result.setAside.append(SetAsideApplication(
                        name: name,
                        reason: "Could not be moved to the Trash. No related files were removed."
                    ))
                } else {
                    result.uninstalled.append(name)
                    result.survivorCount += outcome.failed.count
                    selectedApplicationIDs.remove(plan.applicationURL.path)
                }
            }
        }

        batchUninstallReview = nil
        // The done page lists what was uninstalled and what is still installed.
        batchUninstallOutcome = result

        pruneVanishedEntries()
        activity = nil
        await refreshAfterRemoval()
    }

    /// Kept on for the receipt checkbox in the clean-up sheet.
    var keepReceipt = true

    /// Exactly what the confirmation was asked about: which entries, and whether
    /// they go to the Trash.
    ///
    /// Captured when the sheet opens rather than read again when it is confirmed:
    /// the plan the user agreed to is the plan that runs.
    ///
    /// It carried a `trashFirst` flag, for a preference — "Always move to Trash,
    /// never delete" — that let a Scanner clean-up unlink files outright. The
    /// preference was removed on 20 Sep 2026 (the owner's call): every other
    /// removal in the app already went to the Trash, a cleaner that deletes for
    /// good on a setting the user flipped months ago is a trap, and the Trash is
    /// what Put Back, the receipts and History are built on. A clean-up moves to
    /// the Trash, and space comes back when the Trash is emptied.
    /// `CleanupService.remove(trashFirst:)` keeps its parameter, as a Core primitive
    /// with its tests, and the app always passes `true`.
    struct CleanupPlan {
        let entries: [FileEntry]
        let userDataRemovalOverrides: Set<FileEntry.ID>
        let applicationLeftoverPlan: OrphanedAppLeftoverPlan?
        let orphanedApplicationBundleIdentifiers: Set<String>
        let orphanedApplicationItemPaths: Set<String>
        /// Applications that own something in this plan and were open when the
        /// sheet was — checked against NSWorkspace at capture, not read off the
        /// scan, so an app the user has since quit is not named.
        var runningOwners: [FileEntry.RunningOwner] = []

        /// What this plan would actually free, filled in after the sheet is already
        /// on screen. The plan itself is fixed at capture; this is a reading of the
        /// same set taken a moment later, and it changes nothing the confirmation
        /// executes — only what it tells the user to expect.
        ///
        /// `nil` while the measurement is still running, or when the filesystem
        /// would not answer, and the sheet then says nothing rather than guessing.
        var freed: PrivateSizeMeasurement?

        var orphanedApplicationItems: [AppUninstallPlan.Item] {
            applicationLeftoverPlan?.groups.filter {
                orphanedApplicationBundleIdentifiers.contains($0.bundleIdentifier)
            }.flatMap(\.items).filter {
                orphanedApplicationItemPaths.contains($0.id)
            } ?? []
        }

        var itemCount: Int {
            entries.count + orphanedApplicationItems.count
        }
        var totalBytes: Int64 {
            let ordinary = entries.reduce(0) { total, entry in
                total + CleanupService.removalTargets(
                    for: entry,
                    removeProtectedAppData: false
                ).reduce(0) { $0 + $1.allocatedBytes }
            }
            return ordinary + orphanedApplicationItems.reduce(0) { $0 + $1.allocatedBytes }
        }
        /// Rows the user deliberately unlocked. The final confirmation calls these
        /// out separately from ordinary cache removal.
        var protectedDataCount: Int {
            var protectedIDs: Set<FileEntry.ID> = []
            for entry in entries {
                if entry.protectionReason == .userData,
                   userDataRemovalOverrides.contains(entry.id) {
                    protectedIDs.insert(entry.id)
                }
            }
            let orphanedCount = orphanedApplicationItems.filter(\.isProtectedUserData).count
            return protectedIDs.count + orphanedCount
        }
    }

    private(set) var pendingCleanUp: CleanupPlan?

    /// The route for every Clean Up button: the confirmation sheet, unless the
    /// user switched confirmation off in Advanced — their call, made deliberately
    /// in Preferences, so honouring it is not the app being reckless.
    func requestCleanUp() {
        guard activity == nil else { return }
        let entries = selectedEntries
        let selectedIDs = Set(entries.map(\.id))
        let orphanedIdentifiers = selectedOrphanBundleIdentifiersFromScanner
        let orphanedItemPaths = Set(
            selectedOrphanApplicationEntries.flatMap(\.children).map(\.id)
        )
        let orphanedPlan = scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .applicationLeftoverPlan
        let plan = CleanupPlan(
            entries: entries,
            // Capture authorizations only for rows in this exact operation. The
            // service therefore cannot receive a broader capability than it needs.
            userDataRemovalOverrides: userDataRemovalOverrides.intersection(selectedIDs),
            applicationLeftoverPlan: orphanedPlan,
            orphanedApplicationBundleIdentifiers: orphanedIdentifiers,
            orphanedApplicationItemPaths: orphanedItemPaths
        )
        guard !plan.entries.isEmpty || !plan.orphanedApplicationBundleIdentifiers.isEmpty
        else { return }
        var captured = plan
        captured.runningOwners = Self.stillRunning(
            entries.flatMap {
                CleanupService.removalTargets(for: $0, removeProtectedAppData: false)
            }.compactMap(\.inUseBy)
        )
        pendingCleanUp = captured

        // A global "don't ask" preference never suppresses the warning for data the
        // user had to unlock explicitly — nor the one about open applications,
        // since the sheet is the only place that offers to quit them.
        if settings?.confirmBeforeCleanup ?? true || plan.protectedDataCount > 0
            || !captured.runningOwners.isEmpty {
            activeSheet = .cleanUp
            measureCleanUpSaving(for: plan)
        } else {
            Task { await performCleanUp() }
        }
    }

    /// Reads how much of the pending plan the disk would actually give back.
    ///
    /// Runs *after* the sheet is presented, never before: the walk costs one
    /// `getattrlist` per file, and a plan holding a DerivedData tree would keep the
    /// user staring at a button that had not appeared yet. The sheet opens on the
    /// figures it always had and gains this one when it arrives.
    private func measureCleanUpSaving(for plan: CleanupPlan) {
        let urls = plan.entries.flatMap {
            CleanupService.removalTargets(for: $0, removeProtectedAppData: false).map(\.url)
        } + plan.orphanedApplicationItems.map(\.url)
        guard !urls.isEmpty else { return }

        cleanUpSavingTask?.cancel()
        cleanUpSavingTask = Task { [weak self] in
            let measurement = try? await PrivateSizeMeasurer().measure(urls)
            guard !Task.isCancelled, let measurement else { return }
            // The plan may have been confirmed or cancelled while this ran. Only a
            // sheet still showing the same plan may be updated.
            guard let self, self.activeSheet == .cleanUp else { return }
            self.pendingCleanUp?.freed = measurement
        }
    }

    private var cleanUpSavingTask: Task<Void, Never>?

    /// Dismissing the sheet abandons the plan; nothing may run afterwards.
    func cancelCleanUp() {
        cleanUpSavingTask?.cancel()
        cleanUpSavingTask = nil
        pendingCleanUp = nil
        activeSheet = nil
    }

    // MARK: - Open applications

    /// Every open application the user could be asked to quit, as Core's
    /// `RunningOwner`.
    ///
    /// Ordinary Dock applications only. The first real scan named "Siri" as an
    /// owner — a background agent — and by the same reading Finder, or Scolo's own
    /// cache folder, would put Finder or Scolo on the list "Quit and Clean" works
    /// through. An owner is something the user opened and can close.
    static func currentRunningOwners() -> [FileEntry.RunningOwner] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier,
                  application.bundleIdentifier != "com.apple.finder"
            else { return nil }
            guard let url = application.bundleURL else { return nil }
            return FileEntry.RunningOwner(
                name: application.localizedName
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: url.path
            )
        }
    }

    /// The live processes behind one owner: the application itself and every helper
    /// embedded in its bundle, the same net the uninstaller casts.
    private static func processes(of owner: FileEntry.RunningOwner) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: owner.bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { application in
            if let identifier = owner.bundleIdentifier,
               application.bundleIdentifier == identifier { return true }
            guard let url = application.bundleURL?.standardizedFileURL else { return false }
            return url.path == path || url.path.hasPrefix(path + "/")
        }
    }

    /// The owners among these that are open right now, once each.
    private static func stillRunning(
        _ owners: [FileEntry.RunningOwner]
    ) -> [FileEntry.RunningOwner] {
        var seen: Set<FileEntry.RunningOwner> = []
        return owners.filter { seen.insert($0).inserted && !processes(of: $0).isEmpty }
    }

    /// Asks each owner to quit and waits. Returns the ones that stayed.
    ///
    /// `terminate()`, never `forceTerminate()`: a browser with forty tabs or an
    /// Xcode with unsaved files may put up a prompt, and that prompt is the user's
    /// to answer. Hence 30 s and not the uninstaller's 3 — measured against nothing;
    /// it is a guess at how long a person takes to press Save.
    private func quit(_ owners: [FileEntry.RunningOwner]) async -> [FileEntry.RunningOwner] {
        activity = .waitingForApplicationsToQuit(names: owners.map(\.name))
        for owner in owners {
            for process in Self.processes(of: owner) { process.terminate() }
        }
        for _ in 0..<300 where !Self.stillRunning(owners).isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.stillRunning(owners)
    }

    /// The owners are gone, so the rows they held are ordinary caches again: the
    /// ones this clean-up leaves behind go back to Safe to Remove without a rescan.
    private func clearInUse(of owners: [FileEntry.RunningOwner]) {
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

    // MARK: - Removal

    private let cleanupService = CleanupService()

    /// Performs the clean-up the sheet just confirmed.
    ///
    /// Freed bytes come from `CleanupOutcome`, measured immediately before each
    /// removal — never from the selection total, which would report what we *hoped*
    /// to free rather than what actually went.
    ///
    /// - Parameter quittingOwners: ask the plan's open applications to quit first.
    ///   If any of them is still there when the wait ends, **nothing is removed**:
    ///   the user asked for a clean-up without a live owner, and quietly doing the
    ///   other kind is how Chrome lost its dictionaries.
    func performCleanUp(quittingOwners: Bool = false) async {
        // The captured plan, never the live settings — see `CleanupPlan`.
        guard let plan = pendingCleanUp, activity == nil else { return }

        if quittingOwners, !plan.runningOwners.isEmpty {
            cleanUpSavingTask?.cancel()
            // The sheet goes first or the overlay that says what is happening
            // would sit underneath it.
            activeSheet = nil
            let stragglers = await quit(plan.runningOwners)
            guard stragglers.isEmpty else {
                activity = nil
                pendingCleanUp = nil
                let names = ListFormatter.localizedString(byJoining: stragglers.map(\.name))
                report(
                    "Nothing Was Removed",
                    "\(names) did not quit, so Scolo stopped before touching anything. "
                        + "Quit it yourself and try Clean Up again."
                )
                return
            }
            clearInUse(of: plan.runningOwners)
        }

        // The overlay says what is happening while it happens.
        activity = .cleaningUp(itemCount: plan.itemCount, totalBytes: plan.totalBytes)
        defer { activity = nil }
        let entries = plan.entries
        pendingCleanUp = nil
        activeSheet = nil

        var outcome = CleanupOutcome()
        if !entries.isEmpty {
            let ordinary = (try? await cleanupService.remove(
                entries: entries,
                trashFirst: true,
                // Root-owned App Store installs need Finder's remedy: one admin
                // prompt. Only the app enables this fallback.
                privilegedFallback: true,
                keepReceipt: keepReceipt,
                userDataRemovalOverrides: plan.userDataRemovalOverrides
            )) ?? CleanupOutcome(failed: entries.map(\.id))
            outcome.merge(ordinary)
        }

        if let leftoverPlan = plan.applicationLeftoverPlan,
           !plan.orphanedApplicationBundleIdentifiers.isEmpty {
            let registeredIdentifiers = Self.registeredApplicationBundleIdentifiers(
                for: plan.orphanedApplicationBundleIdentifiers
            )
            let orphaned = (try? await cleanupService.removeOrphanedAppLeftovers(
                leftoverPlan,
                bundleIdentifiers: plan.orphanedApplicationBundleIdentifiers,
                itemPaths: plan.orphanedApplicationItemPaths,
                registeredApplicationBundleIdentifiers: registeredIdentifiers,
                privilegedFallback: true,
                keepReceipt: keepReceipt
            )) ?? CleanupOutcome(
                failed: plan.orphanedApplicationItems.map { $0.url.path }
            )
            outcome.merge(orphaned)
        }

        deselectAll()
        // The Uninstaller's list of leftovers was read from the disk this changed.
        if applicationLeftovers != nil, !plan.orphanedApplicationBundleIdentifiers.isEmpty {
            selectedLeftoverIdentifiers.subtract(plan.orphanedApplicationBundleIdentifiers)
            loadApplicationLeftovers()
        }
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
                copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
                return copy
            }
            scanResults = results
        }
        pruneVanishedEntries()

        let deniedAppDataCount = outcome.permissionDenied.filter {
            Self.isAppDataPath($0)
        }.count
        if deniedAppDataCount > 0 {
            // Its own alert, because it is the one failure with a remedy: the
            // permission is granted in System Settings, and the alert offers to
            // open it.
            isShowingAppDataAccessAlert = true
        } else if let unfinished = Self.cleanUpNotice(outcome) {
            notice = unfinished
        }
        // The removal is over. The window comes back here, before the disk is
        // walked again — see `activity`.
        activity = nil
        await refreshAfterRemoval()
    }

    /// The disk changed, so the cached breakdown and the Trash summary are both
    /// wrong. They run together: the Trash read is usually quick and feeds the
    /// sidebar count, and it should not queue behind a 20-second walk.
    private func refreshAfterRemoval() async {
        // Every cached Explorer level is stale too: a folder measured before a
        // Scanner clean-up came back from the cache with its old figure.
        storageExplorer.invalidateCache()
        async let trash: Void = loadTrash()
        // `removal` marks this measurement as the post-clean-up baseline, which is
        // what "since the last clean-up" reads and what the ring never thins away.
        await measureStorage(trigger: .removal)
        await trash
    }

    /// What is left to say once a clean-up has finished, or nil when it did what
    /// it said it would.
    ///
    /// Nothing is reported for a clean run. The figures were on the confirmation
    /// sheet before the user agreed — the size, and how much of it APFS will
    /// actually give back — and the result is the rows leaving the list and the
    /// Dashboard being measured again. A partial failure is different in kind:
    /// silent partial failure is how a cleaner loses trust.
    private static func cleanUpNotice(_ outcome: CleanupOutcome) -> Notice? {
        guard !outcome.failed.isEmpty else { return nil }
        let count = outcome.failed.count
        let one = count == 1
        if outcome.removedCount == 0 {
            return Notice(
                title: "Nothing Was Removed",
                message: one
                    ? "The selected item could not be removed. It is where it was."
                    : "None of the \(count) selected items could be removed. "
                        + "They are where they were."
            )
        }
        return Notice(
            title: "Some Items Could Not Be Removed",
            message: "\(count) \(one ? "item" : "items") could not be removed; "
                + "the other \(outcome.removedCount) moved to the Trash."
        )
    }

    private static func isAppDataPath(_ path: String) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path
        return path.hasPrefix(library + "/Containers/")
            || path.hasPrefix(library + "/Group Containers/")
    }

    // MARK: - Cleanup history

    private let cleanupHistoryService = CleanupHistoryService()
    var cleanupHistory: CleanupHistorySummary?
    var isLoadingCleanupHistory = false

    func loadCleanupHistory() async {
        guard !isLoadingCleanupHistory else { return }
        isLoadingCleanupHistory = true
        let service = cleanupHistoryService
        cleanupHistory = await Task.detached {
            service.summary()
        }.value
        isLoadingCleanupHistory = false
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
        guard activity == nil else { return }
        activeSheet = nil
        activity = .emptyingTrash(
            itemCount: trashSummary?.itemCount ?? 0,
            totalBytes: trashSummary?.totalBytes ?? 0
        )
        defer { activity = nil }
        do {
            let result = try await trashService.empty(privilegedFallback: true)
            if result.skipped > 0 {
                let one = result.skipped == 1
                report(
                    "The Trash Is Not Empty",
                    "\(result.skipped) \(one ? "item" : "items") could not be removed. "
                        + "\(one ? "It is" : "They are") still in the Trash."
                )
                // Stay on the Trash, where what is left is listed.
            } else {
                // Nothing left to look at here, and what was reclaimed is the
                // figure the Dashboard is about to show.
                view = .dashboard
            }
        } catch {
            // Do not pretend. Name the remedy: this is what a denied read looks
            // like, and the permission is the fix.
            report(
                "The Trash Could Not Be Read",
                "Grant Scolo Full Disk Access in System Settings, Privacy & Security, "
                    + "then try again."
            )
        }
        // Re-read under the scrim, so the Trash never lifts it over rows that are
        // gone. The disk walk runs after, on the Dashboard's own skeleton.
        await loadTrash()
        activity = nil
        // Emptying the Trash frees space, so this measurement is a clean-up
        // baseline like any other removal's.
        await measureStorage(trigger: .removal)
    }

    func putBack(_ item: TrashItem) async {
        do {
            // The row leaves the Trash list below, which is the whole report.
            try await trashService.putBack(item)
        } catch TrashError.destinationOccupied {
            report(
                "\(item.name) Was Not Put Back",
                "Something is already at the place it came from. "
                    + "Move that aside, or drag this out of the Trash yourself."
            )
        } catch {
            report("\(item.name) Was Not Put Back", "It is still in the Trash.")
        }
        await loadTrash()
        await loadCleanupHistory()
    }

    // MARK: - Loading

    // MARK: - iCloud

    private let iCloudService = ICloudStorageService()
    /// Nil until measured, and nil again if iCloud Drive is not signed in — the card
    /// disappears rather than rendering an empty account, which would read as "you
    /// have nothing in iCloud".
    var iCloudStorage: ICloudStorage?

    /// The plan size the user set in Preferences, if any. macOS reports no such
    /// figure, so without this the service infers it from the free space.
    var iCloudPlanBytes: Int64?

    func loadICloud() async {
        iCloudStorage = try? await iCloudService.storage(planBytes: iCloudPlanBytes)
    }

    private let diskInfo = DiskInfoService()
    private let snapshotService = SnapshotService()
    /// Never follows symlinks. The card's contract is that every byte of capacity
    /// is accounted for exactly once, and a link's target already belongs to
    /// whichever category owns its real location — counting it again here put a
    /// 228 GB disk at 274 GB and pushed the bar off the card.
    private let breakdownService = StorageBreakdownService()
    private let lowDiskNotifications = LowDiskNotificationService()
    private let coordinator = ScanCoordinator.standard()
    private var scanTask: Task<Void, Never>?

    /// Last measured figures, shown immediately on launch.
    private(set) var measuredAt: Date?
    var breakdownIsStale: Bool {
        guard let measuredAt else { return true }
        return Date().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }

    /// Loads the Dashboard. Cached figures seed its layout while the skeleton stays
    /// visible. A fresh measurement always follows. The Dashboard presents only the
    /// completed refresh as real data. This prevents a stale-bar flash at launch.
    ///
    /// The cache supplies the first frame but does not replace measurement.
    /// Stable build signing now keeps the TCC grant across launches.
    func loadDashboard() async {
        // A recreated main window runs this task again. Treat that refresh like the
        // first one too, rather than briefly presenting cached values as final.
        hasCompletedInitialDashboardLoad = false
        defer { hasCompletedInitialDashboardLoad = true }

        if let cached = BreakdownCache.load() {
            volume = cached.volume
            breakdown = cached.breakdown
            measuredAt = cached.measuredAt
        }

        // Snapshot listing touches no user files and is safe on every launch.
        // `measureStorage` refreshes volume totals and checks the low-space threshold.
        snapshots = (try? await snapshotService.listAll()) ?? []

        // The growth report is dated history, so the one the previous session left
        // is already true. Reading it first puts it on screen at once instead of
        // leaving the card blank for the length of a disk walk.
        await loadStorageHistory()

        await measureStorage(trigger: .launch)
    }

    /// Walks the disk. Only ever called deliberately.
    ///
    /// - Parameter trigger: what caused this measurement. It is stored with the
    ///   snapshot, and `removal` is the one "since the last clean-up" reads, so a
    ///   wrong trigger costs the user a baseline rather than a figure.
    func measureStorage(trigger: SnapshotTrigger = .manual) async {
        guard !isLoadingBreakdown else { return }
        isLoadingBreakdown = true
        defer { isLoadingBreakdown = false }

        // iCloud rides along with every measurement, so the account card stays in
        // step with the main card. Cheap enough to piggyback: one `brctl` call and
        // a walk of the ubiquity container, where evicted files are stubs on disk.
        Task { await self.loadICloud() }

        // `diskutil info` is cheap and not TCC-gated. Refreshing here keeps the menu
        // bar, Dashboard warning and system notification in step after cleanup too.
        await refreshVolumeInfo()

        // `measure` rather than `breakdown`: the same single walk, with the folder
        // tables it produced kept instead of thrown away. The growth report reads
        // those, and a second traversal to collect them would double the cost of
        // the most expensive measurement in the app.
        guard let measured = try? await breakdownService.measure() else { return }
        breakdown = measured.breakdown

        // The walk takes time. Read the volatile volume figures again, then put
        // Available, Free, and the sidebar on this one completed snapshot.
        await refreshVolumeInfo()
        measuredAt = Date()

        if let volume, let breakdown {
            BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: Date()).save()
        }

        await recordSnapshot(of: measured, trigger: trigger)
    }

    // MARK: - What grew

    /// The ring of dated measurements the Dashboard compares. One JSON file per
    /// measurement; ``StorageSnapshotStore`` documents the retention rules.
    private let snapshotStore = StorageSnapshotStore()

    /// Every stored measurement, newest first. Held in memory so that changing the
    /// baseline is arithmetic over figures already read, not a second disk walk.
    @ObservationIgnored private var storageHistory: [StorageSnapshot] = []

    /// What changed since the chosen baseline.
    ///
    /// `nil` until the history has been read. The Dashboard draws no growth card at
    /// all until then, rather than announcing "first measurement" before it has
    /// looked at what is stored.
    private(set) var growth: GrowthComparison?

    /// Which stored measurement the report compares against.
    ///
    /// Persisted: it is how the user reads the card, not a per-session choice.
    var growthBaseline: GrowthBaseline = UserDefaults.standard.string(forKey: "growthBaseline")
        .flatMap(GrowthBaseline.init(rawValue:)) ?? .sevenDays {
        didSet {
            guard growthBaseline != oldValue else { return }
            UserDefaults.standard.set(growthBaseline.rawValue, forKey: "growthBaseline")
            // Nothing is measured again. Every baseline is a different subtraction
            // over the same stored figures.
            recomputeGrowth()
        }
    }

    /// Reads the stored measurements without walking anything.
    private func loadStorageHistory() async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { store.load() }.value
        recomputeGrowth()
    }

    /// Stores one finished measurement, then recomputes the report.
    ///
    /// All of it runs off the main actor: ``SnapshotCapture`` reads one `device:inode`
    /// per recorded folder — a few hundred on this Mac — and the store then writes a
    /// file and prunes the ring. Only the finished history comes back.
    ///
    /// A measurement whose segments do not sum to capacity is never stored:
    /// ``SnapshotCapture/snapshot(from:trigger:now:id:minimumNodeBytes:maximumNodes:identity:)``
    /// returns nil for it. One dropped snapshot costs one comparison; a stored bad
    /// one would poison every future comparison.
    private func recordSnapshot(
        of measurement: StorageMeasurement,
        trigger: SnapshotTrigger
    ) async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { () -> [StorageSnapshot] in
            if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) {
                try? store.save(snapshot)
            }
            return store.load()
        }.value
        recomputeGrowth()
    }

    private func recomputeGrowth() {
        growth = StorageGrowth.comparison(growthBaseline, in: storageHistory)
    }

    /// Preferences › Advanced › "Clear measurement history".
    ///
    /// The breakdown cache is a different file and a different button: this one
    /// removes the dated measurements the Dashboard subtracts, and the next two
    /// measurements start a new history.
    func clearMeasurementHistory() {
        try? snapshotStore.clear()
        storageHistory = []
        growth = .insufficientHistory
    }

    /// Opens the Storage Explorer at the folder the growth report named.
    ///
    /// The Explorer measures the *parent*, because it lists a folder's children:
    /// opening the changed folder itself would show what is inside it and hide the
    /// row the user clicked. The row is selected once that measurement arrives —
    /// the Explorer clears its selection on every load, so the request travels with
    /// the navigation instead of being written afterwards.
    ///
    /// One disk walk at a time, like every other start button: during a scan or a
    /// removal the click is answered with a reason rather than starting a second
    /// measurement underneath the first.
    func revealGrowth(_ attribution: GrowthAttribution) {
        guard !isBusyWithDisk else {
            report(
                "Scolo Is Already Measuring",
                "Wait for the measurement in progress to finish, then open the folder."
            )
            return
        }
        let url = URL(fileURLWithPath: attribution.path)
        storageExplorer.selectLocation(url.deletingLastPathComponent(), revealing: url)
        view = .storageExplorer
    }

    /// Refreshes only the cheap volume totals, without walking user folders. This is
    /// safe to run periodically and is the observation point for low-space alerts.
    private func refreshVolumeInfo() async {
        volume = (try? await diskInfo.volumeInfo()) ?? volume
        if let volume, let breakdown {
            self.breakdown = breakdown.reconcilingVolume(
                capacityBytes: volume.capacityBytes,
                freeBytes: volume.freeBytes
            )
        }
        guard let volume, let settings else { return }
        await lowDiskNotifications.observe(
            freeBytes: volume.freeBytes,
            volumeName: volume.name,
            thresholdGB: settings.warnBelowGB
        )
    }

    /// Re-entrancy is the coordinator's job; this only drives the UI state.
    ///
    /// - Parameter automatic: set by the scheduler. A scan the user did not ask for
    ///   must not steal the view they are looking at; the status bar and the
    ///   toolbar's progress readout say it is running.
    func startScan(automatic: Bool = false) {
        // Not during a removal either: a scan replaces the results the removal
        // is about to edit, and the scheduler can fire at any moment.
        guard !isBusyWithDisk else { return }
        // An override belongs to one reviewed result set. Carrying it into a fresh
        // scan would turn a newly discovered row into an authorized deletion merely
        // because it reused the same path.
        let destructiveOverrides = userDataRemovalOverrides
        scannerSelection.subtract(destructiveOverrides)
        userDataRemovalOverrides.removeAll()
        isScanning = true
        scanProgress = 0
        if !automatic { view = .scanner }

        // The breakdown refresh runs alongside the scan, not after it: the
        // Dashboard's main card should already be recalculating by the time the
        // user looks at it, and the scan is paying the traversal cost anyway.
        //
        // The scheduler's scan is the one that fills the ring while nobody is
        // looking, so it is stored under its own trigger.
        Task { await self.measureStorage(trigger: automatic ? .scheduled : .scan) }

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
                // The same truth with names attached, so a cache can say whose it
                // is — see `FileEntry.inUseBy`.
                let runningOwners = Self.currentRunningOwners()
                // The preferences' whole reason to exist flows in here: exclusions
                // and disabled categories were all collected and then ignored until this call passed them.
                let settings = self.settings
                let enabled = settings.map { store in
                    Set(CategoryID.allCases.filter { store.isEnabled($0) })
                }
                // One candidate scan, resolved once, handed to the planner whole:
                // scanning twice let an identifier appear between the two passes
                // and reach the planner with no owner check at all. The directory
                // reads run off the main actor; the Launch Services lookups stay
                // on it, since NSWorkspace is main-actor bound and they are cheap.
                var registeredIdentifiers: Set<String> = []
                var leftoverCandidates: OrphanedAppLeftoverPlanner.CandidateScan?
                if enabled?.contains(.applicationLeftovers) ?? true {
                    let planner = self.orphanedAppLeftoverPlanner
                    let candidates = await Task.detached { planner.scanCandidates() }.value
                    leftoverCandidates = candidates
                    registeredIdentifiers = Self.registeredApplicationBundleIdentifiers(
                        for: candidates.identifiers
                    )
                }
                let context = ScanContext(
                    // Never follows symlinks. A scan produces removal candidates,
                    // and removing a row unlinks the link — the target keeps its
                    // bytes — so counting them would make the confirmation promise
                    // gigabytes that stay exactly where they are.
                    measurer: AllocatedSizeMeasurer(followSymlinks: false),
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    runningApplicationPaths: running,
                    runningApplications: runningOwners,
                    registeredApplicationBundleIdentifiers: registeredIdentifiers,
                    applicationLeftoverCandidates: leftoverCandidates
                )
                let results = try await coordinator.scan(
                    enabled: enabled,
                    context: context,
                    onProgress: { progress in
                        Task { @MainActor in self.scanProgress = progress.percent }
                    }
                )
                self.scanResults = results
                self.lastScanFinishedAt = results.finishedAt
                UserDefaults.standard.set(results.finishedAt, forKey: "lastScanFinishedAt")
                // Fresh results arrive collapsed. Closed rows form a short summary
                // the user can take in at a glance, and opening one is a click.
                self.openCategories = []
                // What the scan found is the page the user is looking at.
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                self.report(
                    "The Scan Did Not Finish",
                    "Scolo could not finish measuring. Nothing was removed; try scanning again."
                )
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        Task { await coordinator.cancel() }
    }

    // MARK: - File duplicates

    private let fileDuplicateService = FileDuplicateService()
    private let fileDuplicateRemovalService = FileDuplicateRemovalService()
    @ObservationIgnored private var fileDuplicateTask: Task<Void, Never>?

    var fileDuplicateResults: FileDuplicateResults?
    var fileDuplicateProgress: FileDuplicateService.Progress?
    var isScanningDuplicateFiles = false
    var fileDuplicateSelection: Set<DuplicateFile.ID> = []
    var fileDuplicateMinimumBytes: Int64 = 1_000_000

    var fileDuplicateGroups: [FileDuplicateGroup] {
        fileDuplicateResults?.groups ?? []
    }

    var fileDuplicateSelectionBytes: Int64 {
        fileDuplicateGroups
            .flatMap(\.removable)
            .filter { fileDuplicateSelection.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    var fileDuplicateSelectionLabel: String {
        guard !fileDuplicateSelection.isEmpty else { return "Move to Trash" }
        let files = fileDuplicateSelection.count == 1 ? "File" : "Files"
        return "Move \(fileDuplicateSelection.count) \(files) to Trash"
    }

    func chooseFileDuplicateFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Scan"
        panel.message = "Scolo compares the contents of files in these folders."
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        Task { @MainActor in
            guard await panel.presentAsSheet() == .OK else { return }
            startFileDuplicateScan(roots: panel.urls)
        }
    }

    func startFileDuplicateScan(roots: [URL]? = nil) {
        guard !isBusyWithDisk else { return }
        let scanRoots = roots ?? fileDuplicateResults?.roots ?? []
        if scanRoots.isEmpty {
            chooseFileDuplicateFolders()
            return
        }

        isScanningDuplicateFiles = true
        fileDuplicateProgress = .init(stage: .enumerating)
        fileDuplicateSelection.removeAll()
        duplicateKind = .files
        view = .duplicates

        fileDuplicateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanningDuplicateFiles = false
                self.fileDuplicateTask = nil
            }
            do {
                let results = try await fileDuplicateService.scan(
                    roots: scanRoots,
                    options: .init(minimumLogicalBytes: fileDuplicateMinimumBytes),
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    onProgress: { progress in
                        Task { @MainActor in self.fileDuplicateProgress = progress }
                    }
                )
                // The results page counts what was checked and what was found.
                fileDuplicateResults = results
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                report(
                    "The Duplicate Scan Did Not Finish",
                    "Scolo could not finish comparing those folders. Try scanning again."
                )
            }
        }
    }

    func cancelFileDuplicateScan() {
        fileDuplicateTask?.cancel()
        Task { await fileDuplicateService.cancel() }
    }

    func selectAllFileDuplicates() {
        fileDuplicateSelection = Set(fileDuplicateGroups.flatMap(\.removable).map(\.id))
    }

    func deselectAllFileDuplicates() {
        fileDuplicateSelection.removeAll()
    }

    func toggleFileDuplicate(_ fileID: DuplicateFile.ID) {
        if fileDuplicateSelection.contains(fileID) {
            fileDuplicateSelection.remove(fileID)
        } else {
            fileDuplicateSelection.insert(fileID)
        }
    }

    func toggleFileDuplicateGroup(_ group: FileDuplicateGroup) {
        let ids = Set(group.removable.map(\.id))
        if ids.isSubset(of: fileDuplicateSelection) {
            fileDuplicateSelection.subtract(ids)
        } else {
            fileDuplicateSelection.formUnion(ids)
        }
    }

    func keepFileInstead(groupID: String, fileID: DuplicateFile.ID) {
        guard var results = fileDuplicateResults,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(fileID)
        else { return }

        let groupWasSelected = results.groups[index].removable.contains {
            fileDuplicateSelection.contains($0.id)
        }
        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        fileDuplicateResults = results
        fileDuplicateSelection.remove(fileID)
        if groupWasSelected { fileDuplicateSelection.insert(previousKeeper) }
    }

    func removeSelectedDuplicateFiles() async {
        let selected = fileDuplicateSelection
        guard !selected.isEmpty, activity == nil else { return }
        activeSheet = nil
        activity = .removingDuplicateFiles(
            itemCount: selected.count,
            totalBytes: fileDuplicateSelectionBytes
        )
        defer { activity = nil }

        do {
            let result = try await fileDuplicateRemovalService.remove(
                selectedIDs: selected,
                from: fileDuplicateGroups,
                privilegedFallback: true,
                keepReceipt: keepReceipt
            )
            let outcome = result.cleanup
            let failed = Set(outcome.failed)
            let removed = selected.subtracting(failed)
            let noLongerVerified = removed.union(result.staleFileIDs)
            if var results = fileDuplicateResults {
                results.groups = results.groups.compactMap { group in
                    guard !result.staleGroupIDs.contains(group.id) else { return nil }
                    return group.removingFiles(withIDs: noLongerVerified)
                }
                fileDuplicateResults = results
            }
            fileDuplicateSelection.subtract(noLongerVerified)

            // The container alert names one remedy, and it is the wrong one for a
            // root-owned file in ~/Documents. Same filter as the clean-up path.
            if outcome.permissionDenied.contains(where: Self.isAppDataPath) {
                isShowingAppDataAccessAlert = true
            } else if !outcome.failed.isEmpty || !result.staleFileIDs.isEmpty
                        || !result.staleGroupIDs.isEmpty {
                // A copy that changed since the scan is refused on purpose — every
                // file is hashed again before it moves — and the refusal has to be
                // said, or the tick that stayed behind looks like a bug.
                var message = ""
                if !outcome.failed.isEmpty {
                    let count = outcome.failed.count
                    message = "\(count) \(count == 1 ? "file" : "files") could not move "
                        + "to the Trash. "
                }
                if !result.staleFileIDs.isEmpty || !result.staleGroupIDs.isEmpty {
                    message += "Some copies changed since the scan and were left alone. "
                        + "Scan again to refresh these results."
                }
                report(
                    outcome.removedCount == 0
                        ? "Nothing Was Removed" : "Some Copies Were Left Alone",
                    message.trimmingCharacters(in: .whitespaces)
                )
            }
            activity = nil
            await refreshAfterRemoval()
        } catch is CancellationError {
            // The user stopped it.
        } catch {
            report(
                "The Duplicates Could Not Be Moved",
                "The selected copies could not move to the Trash. Nothing was removed."
            )
        }
    }

    // MARK: - Photo duplicates

    private let photoService = PhotoDuplicateService(
        library: PhotoKitLibrary(),
        visionRevision: UInt32(PhotoKitLibrary.featurePrintRevision)
    )
    private var photoTask: Task<Void, Never>?

    var photoResults: PhotoDuplicateResults?
    var photoProgress: PhotoDuplicateService.Progress?
    var isSweepingPhotos = false
    /// Asset ids the user has marked to delete. Only ever populated from a group's
    /// `removable`, never from `assets` — a keeper cannot reach this set.
    var photoSelection: Set<String> = []
    /// Set when a sweep could not run at all, with copy naming the remedy.
    var photoUnavailable: String?

    /// Groups in date order, newest first.
    ///
    /// Chronology is how people remember photographs, so it is how the review reads —
    /// a trip's worth of near-identical shots arrives together instead of being split
    /// across the list by tier. The tier is still on every group's badge.
    ///
    /// Undated assets sort last rather than first: they would otherwise lead the list
    /// with nothing to explain why.
    var photoGroups: [DuplicateGroup] {
        guard let photoResults else { return [] }
        return photoResults.groups.sorted {
            switch ($0.keeper.creationDate, $1.keeper.creationDate) {
            case let (left?, right?): left == right ? $0.id < $1.id : left > right
            case (nil, _?):           false
            case (_?, nil):           true
            case (nil, nil):          $0.id < $1.id
            }
        }
    }

    var photoSelectionLabel: String {
        photoSelection.isEmpty
            ? "Delete"
            : "Delete \(photoSelection.count) \(photoSelection.count == 1 ? "Photo" : "Photos")"
    }

    func startPhotoSweep() {
        guard !isBusyWithDisk else { return }
        isSweepingPhotos = true
        photoUnavailable = nil
        photoSelection.removeAll()
        view = .duplicates
        duplicateKind = .photos

        photoTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSweepingPhotos = false
                self.photoTask = nil
            }
            do {
                let results = try await photoService.sweep(
                    onProgress: { progress in
                        Task { @MainActor in self.photoProgress = progress }
                    }
                )
                self.photoResults = results
                // Everything removable arrives selected, so the review is a matter of
                // unticking what should stay rather than ticking 990 things that
                // should go. Keepers are still unreachable — the set is built from
                // `removable` alone — and the `Looks similar` badge marks the groups
                // that deserve a second look before the Delete button is pressed.
                self.photoSelection = Set(results.groups.flatMap(\.removable).map(\.id))
                // The results page counts the sets, the photos and what was skipped.
            } catch let unavailable as PhotoSweepUnavailable {
                // Shown on the page, with what to do about it.
                self.photoUnavailable = Self.describe(unavailable)
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                self.report(
                    "The Photo Sweep Did Not Finish",
                    "Scolo could not finish comparing the library. Nothing was deleted; "
                        + "try again."
                )
            }
        }
    }

    func cancelPhotoSweep() {
        photoTask?.cancel()
        Task { await photoService.cancel() }
    }

    private static func describe(_ unavailable: PhotoSweepUnavailable) -> String {
        switch unavailable {
        case .access(let access):
            access.unavailableReason ?? "The photo library is unavailable."
        case .librarySyncing(let count):
            "Only \(count) photos have arrived from iCloud so far. Let Photos finish "
                + "syncing — sweeping now would compare photos against copies that are "
                + "not here yet."
        }
    }

    /// Restores the default: everything the sweep judged removable.
    func selectAllRemovablePhotos() {
        photoSelection = Set(photoGroups.flatMap(\.removable).map(\.id))
    }

    /// Narrows the selection to the **certain** tiers only.
    ///
    /// Bursts come from Photos' own grouping and `exact` is a metadata match that the
    /// feature prints then confirmed; both are safe to take in bulk. `similar` is a
    /// judgement call, and on a real library it accounted for 1,050 of 1,058 groups —
    /// so a select-all that included it would hand the user 1,619 photographs to
    /// delete on the strength of a threshold, which is the exact shape of the bug
    /// that proposed deleting 1,075 distinct photos earlier. Those groups are
    /// selected per group, after looking at them.
    ///
    /// Keepers are unreachable regardless: the set is built from `removable` alone.
    func selectCertainPhotosOnly() {
        photoSelection = Set(
            photoGroups
                .filter { $0.kind != .similar }
                .flatMap(\.removable)
                .map(\.id)
        )
    }

    /// How many photos `selectAllRemovablePhotos` would take, for the button's label.
    var certainRemovableCount: Int {
        photoGroups.filter { $0.kind != .similar }.reduce(0) { $0 + $1.removable.count }
    }

    func deselectAllPhotos() { photoSelection.removeAll() }

    /// Makes `assetID` the copy that survives in its group.
    ///
    /// The promoted photo leaves the selection and the demoted keeper joins it, so
    /// the group still deletes everything but one — the choice moves, the arithmetic
    /// does not.
    func keepInstead(groupID: String, assetID: String) {
        guard var results = photoResults,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(assetID)
        else { return }

        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        photoResults = results

        photoSelection.remove(assetID)
        // Only if the rest of the group was armed; promoting inside a group the user
        // had deliberately cleared should not arm it again behind their back.
        if promoted.removable.contains(where: { photoSelection.contains($0.id) }) {
            photoSelection.insert(previousKeeper)
        }
    }

    func togglePhoto(_ assetID: String) {
        if photoSelection.contains(assetID) {
            photoSelection.remove(assetID)
        } else {
            photoSelection.insert(assetID)
        }
    }

    func deleteSelectedPhotos() async {
        let ids = Array(photoSelection)
        guard !ids.isEmpty else { return }
        activeSheet = nil

        do {
            try await photoService.delete(assetIDs: ids)
            let gone = Set(ids)
            // Drop the deleted assets from every group, and drop any group that no
            // longer has anything to remove — a set showing only its keeper is a row
            // that costs attention and returns nothing.
            if var results = photoResults {
                results.groups = results.groups.compactMap { group in
                    let remaining = group.removable.filter { !gone.contains($0.id) }
                    guard !remaining.isEmpty else { return nil }
                    return DuplicateGroup(
                        id: group.id, kind: group.kind, keeper: group.keeper, removable: remaining
                    )
                }
                photoResults = results
            }
            photoSelection.removeAll()
            // The rows are gone from the page, but the storage is not back: Photos
            // holds a deleted asset for thirty days, and nothing on this screen
            // could tell the user that.
            report(
                "Deleted \(ids.count) \(ids.count == 1 ? "Photo" : "Photos")",
                "They are in Recently Deleted in Photos. Empty it there to reclaim "
                    + "the storage, on this Mac and in iCloud."
            )
        } catch {
            // Deletion is the one operation the user cannot verify at a glance across
            // devices, so a failure is stated rather than left to inference.
            report(
                "Those Photos Were Not Deleted",
                "Photos refused the deletion. Nothing was removed from the library."
            )
        }
    }

}
