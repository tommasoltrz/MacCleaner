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
        case dashboard, scanner, large, trash, photos
        // Reached from the Dashboard tiles, not the sidebar. Back returns.
        case safeToRemove, needsReview
        var id: String { rawValue }

        /// The sidebar's rows. The tile views stay out: they are drill-downs from
        /// the Dashboard, and listing them as siblings would make four views six.
        /// Trash sits last: it is where things end up, not a place to work.
        static var sidebarCases: [View] { [.dashboard, .scanner, .large, .photos, .trash] }

        var title: String {
            switch self {
            case .dashboard:    "Dashboard"
            case .scanner:      "Scanner"
            case .large:        "Large & Old Files"
            case .trash:        "Trash"
            case .photos:       "Photo Duplicates"
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
            case .photos:       "photo.on.rectangle.angled"
            case .safeToRemove: "checkmark.shield"
            case .needsReview:  "questionmark.folder"
            }
        }
    }

    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash, deletePhotos
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

    /// When the last junk scan finished, surviving relaunch. The results themselves
    /// are recomputed on demand — cheap to re-earn, dangerous to trust stale — but
    /// "when did I last scan" is an answer the Dashboard should always have.
    private(set) var lastScanFinishedAt: Date? =
        UserDefaults.standard.object(forKey: "lastScanFinishedAt") as? Date

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
    private let breakdownService = StorageBreakdownService()
    private let coordinator = ScanCoordinator.standard()
    private var scanTask: Task<Void, Never>?

    /// Last measured figures, shown immediately on launch.
    private(set) var measuredAt: Date?
    var breakdownIsStale: Bool {
        guard let measuredAt else { return true }
        return Date().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }

    /// Loads the Dashboard: cached figures paint instantly, a fresh measurement
    /// always follows.
    ///
    /// The cache is a first frame, not a substitute for measuring — yesterday's
    /// breakdown on today's Dashboard reads as a bug. Re-measuring on every launch
    /// used to mean a TCC prompt on every launch, but the build is signed with a
    /// stable identity now, so the grant survives and the walk is silent.
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

        await measureStorage()
    }

    /// Walks the disk. Only ever called deliberately.
    func measureStorage() async {
        guard !isLoadingBreakdown else { return }
        isLoadingBreakdown = true
        defer { isLoadingBreakdown = false }

        // iCloud rides along with every measurement, so the account card stays in
        // step with the main card. Cheap enough to piggyback: one `brctl` call and
        // a walk of the ubiquity container, where evicted files are stubs on disk.
        Task { await self.loadICloud() }

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

        // The breakdown refresh runs alongside the scan, not after it: the
        // Dashboard's main card should already be recalculating by the time the
        // user looks at it, and the scan is paying the traversal cost anyway.
        Task { await self.measureStorage() }

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
                self.lastScanFinishedAt = results.finishedAt
                UserDefaults.standard.set(results.finishedAt, forKey: "lastScanFinishedAt")
                // Fresh results arrive collapsed: seven closed rows are a summary
                // the user can take in at a glance, and opening one is a click.
                self.openCategories = []
                self.statusMessage = "Scan complete. Found "
                    + "\(ByteFormatting.string(results.totalBytes)) in "
                    + "\(results.actionableCategories.count) categories."
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
        guard !isSweepingPhotos else { return }
        isSweepingPhotos = true
        photoUnavailable = nil
        photoSelection.removeAll()
        view = .photos

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
                self.statusMessage = Self.sweepStatus(results)
            } catch let unavailable as PhotoSweepUnavailable {
                self.photoUnavailable = Self.describe(unavailable)
                self.statusMessage = "Photo sweep could not run."
            } catch is CancellationError {
                self.statusMessage = "Photo sweep cancelled"
            } catch {
                self.statusMessage = "Photo sweep failed"
            }
        }
    }

    func cancelPhotoSweep() {
        photoTask?.cancel()
        Task { await photoService.cancel() }
    }

    private static func sweepStatus(_ results: PhotoDuplicateResults) -> String {
        guard !results.groups.isEmpty else {
            var message = "No duplicates found in \(results.examinedCount) photos."
            if results.skippedCount > 0 {
                message += " \(results.skippedCount) could not be read."
            }
            return message
        }
        var message = "Found \(results.groups.count) duplicate sets — "
            + "\(results.removableCount) photos can go."
        // A skipped asset was never compared, so the result is a floor, not a total.
        if results.skippedCount > 0 {
            message += " \(results.skippedCount) photos had no thumbnail and were not compared."
        }
        return message
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
            statusMessage = "Deleted \(ids.count) \(ids.count == 1 ? "photo" : "photos"). "
                + "Empty Recently Deleted in Photos to reclaim the iCloud storage."
        } catch {
            // Deletion is the one operation the user cannot verify at a glance across
            // devices, so a failure is stated rather than left to inference.
            statusMessage = "Those photos could not be deleted."
        }
    }

}
