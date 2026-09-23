import AppKit
import Observation
import ScoloCore

/// Owns feature composition, navigation, and operation routing.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored private let settings: SettingsStore?
    let storageExplorer: StorageExplorerModel
    let storageRemoval: StorageRemovalModel
    let photoDuplicates: PhotoDuplicatesModel
    let fileDuplicates: FileDuplicatesModel
    let cleanup: CleanupModel
    let cleanupRemoval: CleanupRemovalModel
    let dashboard: DashboardModel
    let uninstaller: UninstallerModel
    let history: HistoryModel
    let trash: TrashModel
    let operations: OperationState
    @ObservationIgnored private let scheduler = ScanScheduler()

    init(settings: SettingsStore? = nil, cleanup: CleanupModel? = nil, photoDuplicates: PhotoDuplicatesModel? = nil, startsScheduler: Bool = true) {
        self.settings = settings
        let operations = OperationState()
        let cleanup = cleanup ?? CleanupModel(settings: settings)
        self.operations = operations
        self.cleanup = cleanup
        let storageExplorer = StorageExplorerModel(settings: settings)
        self.storageExplorer = storageExplorer
        self.storageRemoval = StorageRemovalModel(settings: settings, storageExplorer: storageExplorer, operations: operations)
        self.photoDuplicates = photoDuplicates ?? PhotoDuplicatesModel()
        self.fileDuplicates = FileDuplicatesModel(settings: settings, operations: operations)
        self.dashboard = DashboardModel(settings: settings)
        self.uninstaller = UninstallerModel(settings: settings, operations: operations)
        self.cleanupRemoval = CleanupRemovalModel(settings: settings, cleanup: cleanup, operations: operations)
        self.history = HistoryModel()
        self.trash = TrashModel(operations: operations)
        connectFeatures()
        if startsScheduler { scheduler.start() }
    }

    private func connectFeatures() {
        photoDuplicates.onFailure = { [weak operations] in operations?.report($0, $1) }
        cleanup.onFailure = { [weak operations] in operations?.report($0, $1) }
        storageRemoval.canStart = { [weak self] in self.map { !$0.isBusyWithDisk } ?? false }
        storageRemoval.onRemoval = { [weak self] in await self?.refreshAfterRemoval(preserveExplorerCache: true) }
        fileDuplicates.canStart = { [weak self] in self.map { !$0.isBusyWithDisk } ?? false }
        uninstaller.canStart = { [weak self] in self.map { !$0.isBusyWithDisk } ?? false }
        cleanupRemoval.canStart = { [weak self] in self.map { !$0.isBusyWithDisk } ?? false }
        cleanupRemoval.destination = { [weak self] in self?.view ?? .scanner }
        uninstaller.onReview = { [weak self] in self?.view = .uninstaller }
        uninstaller.onRemoval = { [weak self] in
            self?.cleanup.pruneVanishedEntries()
            await self?.refreshAfterRemoval()
        }
        fileDuplicates.onRemoval = { [weak self] in await self?.refreshAfterRemoval() }
        cleanupRemoval.onRemoval = { [weak self] in await self?.refreshAfterRemoval() }
        cleanupRemoval.refreshLeftovers = { [weak uninstaller] identifiers in
            guard let uninstaller, uninstaller.library.applicationLeftovers != nil else { return }
            uninstaller.library.selectedLeftoverIdentifiers.subtract(identifiers)
            uninstaller.library.loadApplicationLeftovers()
        }
        cleanupRemoval.waitForLeftovers = { [weak uninstaller] in await uninstaller?.library.waitForLeftovers() }
        trash.onReveal = { [weak self] in self?.view = .trash }
        trash.onRestore = { [weak history] in await history?.loadCleanupHistory() }
        trash.onRemoval = { [weak dashboard] in await dashboard?.measureStorage(trigger: .removal) }
        scheduler.onTick = { [weak self] in
            guard let self else { return }
            await dashboard.refreshVolumeInfo()
            if scheduledScanIsDue() { startScan(automatic: true) }
        }
    }

    func scheduledScanIsDue() -> Bool {
        guard let settings else { return false }
        return AutomaticScanPolicy.isDue(AutomaticScanPolicy.Conditions(
            now: Date(),
            lastFinished: cleanup.lastScanFinishedAt,
            cadence: settings.scanSchedule.cadence,
            requiresIdleAndPower: settings.idleOnly,
            isOnACPower: ScanScheduler.isOnACPower,
            secondsSinceUserInput: ScanScheduler.secondsSinceUserInput,
            isScanning: cleanup.isScanning
        ))
    }

    var view: AppSection = .scanner {
        didSet {
            if oldValue != view { operations.removalCompletion = nil }
            if oldValue == .scanner, view != .scanner {
                cleanupRemoval.cleanupCompletion = nil
            }
        }
    }

    var duplicateKind: DuplicateKind = .files {
        didSet {
            if oldValue != duplicateKind { operations.removalCompletion = nil }
        }
    }

    private(set) var findRequest = 0

    var canFind: Bool {
        switch view {
        case .trash, .history, .uninstaller: operations.activity == nil
        case .dashboard, .scanner, .storageExplorer, .duplicates: false
        }
    }

    func requestFind() {
        guard canFind else { return }
        findRequest += 1
    }

    func automaticallyDismissRemovalCompletion(_ id: UUID) async {
        guard let completion = operations.removalCompletion,
              completion.id == id,
              completion.dismissesAutomatically else { return }
        let destination = completion.destination

        do {
            try await Task.sleep(for: .seconds(destination == .uninstaller ? 1 : 2))
            // Keep the result visible until the refreshed list is ready.
            while (destination == .storageExplorer && storageExplorer.isLoading)
                || (destination == .uninstaller && uninstaller.library.isLoadingApplicationLeftovers) {
                guard operations.removalCompletion?.id == id, view == destination else { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            return
        }

        guard operations.removalCompletion?.id == id, view == destination else { return }
        operations.dismissRemovalCompletion()
    }

    func showDashboardAfterCleanup(_ id: UUID) {
        guard cleanupRemoval.cleanupCompletion?.id == id else { return }
        view = .dashboard
    }

    var isStorageExplorerMeasurementBlocked: Bool {
        cleanup.isScanning || fileDuplicates.isScanningDuplicateFiles || photoDuplicates.isScanning || photoDuplicates.isDeleting || operations.activity != nil
    }

    var isBusyWithDisk: Bool {
        cleanup.isScanning || fileDuplicates.isScanningDuplicateFiles || photoDuplicates.isScanning || photoDuplicates.isDeleting
            || storageExplorer.isLoading || uninstaller.isPlanningAppUninstall || operations.activity != nil
    }

    var removeLabel: String {
        switch view {
        case .scanner:
            "Move to Trash (\(ByteFormatting.string(cleanup.cleanupSelectionBytes(in: .all))))"
        case .duplicates:
            duplicateKind == .files ? fileDuplicates.fileDuplicateRemoveLabel : photoDuplicates.removeLabel
        case .uninstaller:
            uninstaller.uninstallerRemoveLabel
        case .storageExplorer:
            storageRemoval.storageExplorerRemoveLabel
        case .trash:
            "Empty Trash"
        case .dashboard, .history:
            "Remove"
        }
    }

    func showScanner(filtered filter: CleanupModel.ScanFilter) {
        cleanup.scanFilter = filter
        view = .scanner
    }

    func refreshAfterRemoval(preserveExplorerCache: Bool = false) async {
        // Explorer removals already update the cache. Other removals require a new measurement.
        if !preserveExplorerCache { storageExplorer.invalidateCache() }
        async let trashRefresh: Void = trash.loadTrash()
        // `removal` marks this measurement as the post-clean-up baseline, which is
        // what "since the last clean-up" reads and what the ring never thins away.
        await dashboard.measureStorage(trigger: .removal)
        await trashRefresh
    }

    func revealGrowth(_ attribution: GrowthAttribution) {
        guard !isBusyWithDisk else {
            operations.report(
                "Scolo Is Already Measuring",
                "Wait for the measurement in progress to finish, then open the folder."
            )
            return
        }
        let url = URL(fileURLWithPath: attribution.path)
        storageExplorer.selectLocation(url.deletingLastPathComponent(), revealing: url)
        view = .storageExplorer
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

    func startPhotoSweep() {
        guard !isBusyWithDisk else { return }
        operations.removalCompletion = nil
        view = .duplicates
        duplicateKind = .photos
        photoDuplicates.startScan()
    }

    func deleteSelectedPhotos() async {
        guard !isBusyWithDisk, !photoDuplicates.isRegrouping else { return }
        let removableIDs = Set(photoDuplicates.groups.flatMap(\.removable).map(\.id))
        guard !photoDuplicates.selection.isDisjoint(with: removableIDs) else { return }
        operations.removalCompletion = nil
        await photoDuplicates.deleteSelected { count in
            operations.removalCompletion = OperationState.RemovalCompletion(
                destination: .duplicates,
                title: "Moved to Recently Deleted",
                detail: "\(count) \(count == 1 ? "photo" : "photos"). You can recover them in Photos for up to 30 days."
            )
        }
    }

    func startInitialCleanupScan() {
        guard view == .scanner, cleanup.needsInitialScan,
              cleanupRemoval.cleanupCompletion == nil, !isBusyWithDisk else { return }
        startScan(automatic: true, refreshOverview: false)
    }

    func startScan(automatic: Bool = false, refreshOverview: Bool = true) {
        guard !isBusyWithDisk else { return }
        cleanupRemoval.resetOutcome()
        if !automatic { view = .scanner }
        cleanup.startScan()
        if refreshOverview {
            Task { await dashboard.measureStorage(trigger: automatic ? .scheduled : .scan) }
        }
    }

    func startFileDuplicateScan(roots: [URL]? = nil) {
        guard !isBusyWithDisk else { return }
        let roots = roots ?? fileDuplicates.fileDuplicateResults?.roots ?? []
        guard !roots.isEmpty else { chooseFileDuplicateFolders(); return }
        duplicateKind = .files
        view = .duplicates
        fileDuplicates.startFileDuplicateScan(roots: roots)
    }

    func requestLeftoverRemoval() async {
        guard !isBusyWithDisk, !uninstaller.library.isLoadingApplicationLeftovers,
              let plan = uninstaller.library.applicationLeftovers else { return }
        await cleanupRemoval.removeLeftovers(plan, identifiers: uninstaller.library.selectedLeftoverIdentifiers)
    }
}
