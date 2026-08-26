import SwiftUI
import AppKit
import CoreGraphics
import IOKit.ps
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

    /// The preferences the engine must obey. Injected at launch; optional only so
    /// previews and tests can build a model without a store.
    @ObservationIgnored var settings: SettingsStore?

    init(settings: SettingsStore? = nil) {
        self.settings = settings
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
        case dashboard, scanner, uninstaller, trash, photos
        // Reached from the Dashboard tiles, not the sidebar. Back returns.
        case safeToRemove, needsReview
        var id: String { rawValue }

        /// The sidebar's rows. The tile views stay out: they are drill-downs from
        /// the Dashboard, and listing them as siblings would make four views six.
        /// Destructive workflows sit at the end: review an application's complete
        /// uninstall first, then the Trash where removed items ultimately land.
        static var sidebarCases: [View] {
            [.dashboard, .scanner, .photos, .uninstaller, .trash]
        }

        var title: String {
            switch self {
            case .dashboard:    "Dashboard"
            case .scanner:      "Scanner"
            case .uninstaller:  "App Uninstaller"
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
            case .uninstaller:  "xmark.app"
            case .trash:        "trash"
            case .photos:       "photo.on.rectangle.angled"
            case .safeToRemove: "checkmark.shield"
            case .needsReview:  "questionmark.folder"
            }
        }
    }

    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash, deletePhotos, uninstallApp
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

    var statusMessage: String = "Ready to scan"
    var isCleaningUp = false
    var isShowingAppDataAccessAlert = false

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
    func tileEntries(safeToRemove wantSafe: Bool) -> [FileEntry] {
        guard let results = scanResults else { return [] }
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .flatMap { category in
                category.entries.filter {
                    let isSafe = category.categoryID == .applicationLeftovers
                        || (category.categoryID.isSafe && $0.isRegenerable)
                    return isSafe == wantSafe
                }
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayBytes > $1.displayBytes }
    }

    /// Rows in the current drill-down whose checkbox actually works. A locked entry
    /// — a running app, user data, a manual-removal aggregate — must never be swept
    /// into a total that would then fail at cleanup.
    private var selectableInCurrentView: [FileEntry] {
        switch view {
        case .safeToRemove:
            tileEntries(safeToRemove: true).filter {
                !$0.isRemovalLocked && $0.kind != .appBundle
            }
        case .needsReview:
            tileEntries(safeToRemove: false).filter {
                !$0.isRemovalLocked && $0.kind != .appBundle
            }
        default:            []
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

    /// Opens "Safe to Remove" with everything already ticked.
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

        // Application-leftover groups are never pre-ticked. They sit in this tile
        // because their owner is gone, which is a different claim from "this
        // regenerates": if the classification is ever wrong, a cache comes back
        // and a preferences file does not. The user opts in to those by hand.
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
    var isUninstallingApp = false
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
        isPlanningAppUninstall = true
        view = .uninstaller
        let planningID = UUID()
        appUninstallPlanningID = planningID

        let settings = settings
        let context = ScanContext(
            // Uninstall candidates must always be the paths themselves. Following a
            // symlink would measure bytes that unlinking the candidate cannot free.
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? [],
            protectRecentDays: 0
        )
        let planner = appUninstallPlanner
        appUninstallTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.appUninstallPlanningID == planningID {
                    self.isPlanningAppUninstall = false
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
                if plan.isApplicationOnly {
                    self.statusMessage = "Prepared an application-only uninstall for "
                        + "\(plan.applicationName)."
                } else {
                    self.statusMessage = "Found \(plan.items.count - 1) related items for "
                        + "\(plan.applicationName)."
                }
            } catch is CancellationError {
                return
            } catch {
                self.appUninstallError = error.localizedDescription
                self.statusMessage = "Could not prepare that application for uninstall."
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

    func performAppUninstall() async {
        guard let request = pendingAppUninstall else { return }
        pendingAppUninstall = nil
        activeSheet = nil
        isUninstallingApp = true
        appUninstallError = nil
        defer { isUninstallingApp = false }

        // Ask the selected app and every helper embedded inside its bundle to quit.
        // Cleanup starts only after they are gone; it never force-kills a process
        // that may still be writing settings.
        let targetPath = request.plan.applicationURL.standardizedFileURL.path
        func matchingRunningApplications() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { application in
                guard let url = application.bundleURL?.standardizedFileURL else { return false }
                return url.path == targetPath || url.path.hasPrefix(targetPath + "/")
            }
        }
        for application in matchingRunningApplications() { application.terminate() }
        for _ in 0..<30 where !matchingRunningApplications().isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !matchingRunningApplications().isEmpty {
            appUninstallError = "\(request.plan.applicationName) is still running. "
                + "Quit it and try again; no files were removed."
            statusMessage = "Uninstall stopped because the application did not quit."
            return
        }

        let outcome: CleanupOutcome
        do {
            outcome = try await cleanupService.uninstall(
                request.plan,
                privilegedFallback: true,
                keepReceipt: keepReceipt
            )
        } catch {
            appUninstallError = "The uninstall was interrupted. Review the application and try again."
            statusMessage = "Application uninstall was interrupted."
            return
        }

        appUninstallOutcome = outcome
        lastUninstalledApplicationName = request.plan.applicationName
        appUninstallPlan = nil

        let applicationFailed = outcome.failed.contains(request.plan.applicationURL.path)
        if applicationFailed {
            let relatedFilesMessage = request.plan.isApplicationOnly
                ? "" : " No related files were removed."
            appUninstallError = "\(request.plan.applicationName) could not be moved to the Trash."
                + relatedFilesMessage
            statusMessage = "Could not uninstall \(request.plan.applicationName)."
        } else {
            let survivorCount = outcome.failed.count
            statusMessage = "Uninstalled \(request.plan.applicationName) and moved "
                + "\(ByteFormatting.string(outcome.freedBytes)) to the Trash."
            if survivorCount > 0 {
                let noun = survivorCount == 1 ? "item" : "items"
                statusMessage += " \(survivorCount) related \(noun) could not be removed."
            }
        }

        pruneVanishedEntries()
        await measureStorage()
        await loadTrash()
    }

    /// Kept on for the receipt checkbox in the clean-up sheet.
    var keepReceipt = true

    /// Exactly what the confirmation was asked about: which entries, and whether
    /// they go to the Trash.
    ///
    /// Captured when the sheet opens rather than read again when it is confirmed.
    /// Settings is a separate window that stays usable while the sheet is up, so
    /// turning off "Always move to Trash" mid-confirmation used to make a sheet
    /// promising the Trash perform a permanent deletion. The plan the user agreed
    /// to is the plan that runs.
    struct CleanupPlan {
        let entries: [FileEntry]
        let trashFirst: Bool
        let userDataRemovalOverrides: Set<FileEntry.ID>
        let applicationLeftoverPlan: OrphanedAppLeftoverPlan?
        let orphanedApplicationBundleIdentifiers: Set<String>
        let orphanedApplicationItemPaths: Set<String>

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
        /// How many entries this plan deletes outright — the same rule
        /// `CleanupService` applies, so the sheet's copy cannot drift from what
        /// the service does: everything when `trashFirst` is off, except app
        /// bundles and explicitly unlocked user data, which insist on the Trash.
        var permanentCount: Int {
            trashFirst ? 0 : entries.filter { !CleanupService.alwaysMovesToTrash($0) }.count
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
        guard !isCleaningUp else { return }
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
            trashFirst: settings?.trashFirst ?? true,
            // Capture authorizations only for rows in this exact operation. The
            // service therefore cannot receive a broader capability than it needs.
            userDataRemovalOverrides: userDataRemovalOverrides.intersection(selectedIDs),
            applicationLeftoverPlan: orphanedPlan,
            orphanedApplicationBundleIdentifiers: orphanedIdentifiers,
            orphanedApplicationItemPaths: orphanedItemPaths
        )
        guard !plan.entries.isEmpty || !plan.orphanedApplicationBundleIdentifiers.isEmpty
        else { return }
        pendingCleanUp = plan

        // A global "don't ask" preference never suppresses the warning for data the
        // user had to unlock explicitly.
        if settings?.confirmBeforeCleanup ?? true || plan.protectedDataCount > 0 {
            activeSheet = .cleanUp
        } else {
            Task { await performCleanUp() }
        }
    }

    /// Dismissing the sheet abandons the plan; nothing may run afterwards.
    func cancelCleanUp() {
        pendingCleanUp = nil
        activeSheet = nil
    }

    // MARK: - Removal

    private let cleanupService = CleanupService()

    /// Performs the clean-up the sheet just confirmed.
    ///
    /// Freed bytes come from `CleanupOutcome`, measured immediately before each
    /// removal — never from the selection total, which would report what we *hoped*
    /// to free rather than what actually went.
    func performCleanUp() async {
        // The captured plan, never the live settings — see `CleanupPlan`.
        guard let plan = pendingCleanUp, !isCleaningUp else { return }
        isCleaningUp = true
        statusMessage = "Moving selected items to the Trash…"
        defer { isCleaningUp = false }
        let entries = plan.entries
        pendingCleanUp = nil
        activeSheet = nil

        var outcome = CleanupOutcome()
        if !entries.isEmpty {
            let ordinary = (try? await cleanupService.remove(
                entries: entries,
                trashFirst: plan.trashFirst,
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

        statusMessage = Self.cleanUpStatus(outcome, keptReceipt: keepReceipt)
        let deniedAppDataCount = outcome.permissionDenied.filter {
            Self.isAppDataPath($0)
        }.count
        if deniedAppDataCount > 0 {
            isShowingAppDataAccessAlert = true
            statusMessage += " Allow access to other application data, then try again."
        }
        // The disk changed, so the cached breakdown is now wrong.
        await measureStorage()
        await loadTrash()
    }

    /// Says what actually happened, split the way the outcome is: trashed bytes
    /// invite an undo, deleted bytes must never pretend to.
    private static func cleanUpStatus(_ outcome: CleanupOutcome, keptReceipt: Bool) -> String {
        var message: String
        if outcome.removedCount == 0, !outcome.failed.isEmpty {
            message = "No items were removed."
        } else if outcome.deletedCount == 0 {
            message = "Moved \(ByteFormatting.string(outcome.freedBytes)) to the Trash."
            if outcome.trashedCount > 0 && keptReceipt {
                message += " Put Back is available while those items remain in the Trash."
            }
        } else if outcome.trashedCount == 0 {
            message = "Deleted \(ByteFormatting.string(outcome.freedBytes)) permanently."
        } else {
            message = "Removed \(ByteFormatting.string(outcome.freedBytes)) — "
                + "\(outcome.trashedCount) to the Trash, \(outcome.deletedCount) deleted permanently."
        }
        if !outcome.failed.isEmpty {
            // Silent partial failure is how a cleaner loses trust.
            let noun = outcome.failed.count == 1 ? "item" : "items"
            message += " \(outcome.failed.count) \(noun) could not be removed."
        }
        return message
    }

    private static func isAppDataPath(_ path: String) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path
        return path.hasPrefix(library + "/Containers/")
            || path.hasPrefix(library + "/Group Containers/")
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

        // `diskutil info` is cheap and not TCC-gated. Refreshing here keeps the menu
        // bar, Dashboard warning and system notification in step after cleanup too.
        await refreshVolumeInfo()

        guard let measured = try? await breakdownService.breakdown() else { return }
        breakdown = measured

        // The walk takes time. Read the volatile volume figures again, then put
        // Available, Free, and the sidebar on this one completed snapshot.
        await refreshVolumeInfo()
        measuredAt = Date()

        if let volume, let breakdown {
            BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: Date()).save()
        }
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
        guard !isScanning else { return }
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
                // The preferences' whole reason to exist flows in here: exclusions,
                // the recency shield, the symlink toggle and disabled categories
                // were all collected and then ignored until this call passed them.
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
                    protectRecentDays: settings?.protectRecentDays.rawValue ?? 30,
                    runningApplicationPaths: running,
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
