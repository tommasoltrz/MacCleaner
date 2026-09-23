import AppKit
import Observation
import ScoloCore

/// Owns captured cleanup plans and cleanup removal.
@MainActor
@Observable
final class CleanupRemovalModel {
    @ObservationIgnored private let settings: SettingsStore?
    let cleanup: CleanupModel
    let operations: OperationState
    @ObservationIgnored var canStart: () -> Bool = { true }
    @ObservationIgnored var destination: () -> AppSection = { .scanner }
    @ObservationIgnored var onRemoval: (() async -> Void)?
    @ObservationIgnored var refreshLeftovers: ((Set<String>) -> Void)?
    @ObservationIgnored var waitForLeftovers: (() async -> Void)?

    init(settings: SettingsStore? = nil, cleanup: CleanupModel, operations: OperationState) {
        self.settings = settings
        self.cleanup = cleanup
        self.operations = operations
    }

    func resetOutcome() {
        cleanupOutcome = nil
        cleanupCompletion = nil
    }

    private var keepReceipt: Bool { settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt }

    func removeLeftovers(_ plan: OrphanedAppLeftoverPlan, identifiers: Set<String>) async {
        guard canStart() else { return }
        let items = plan.groups.filter { identifiers.contains($0.bundleIdentifier) }.flatMap(\.items)
        guard !items.isEmpty else { return }
        pendingCleanUp = CleanupPlan(
            entries: [], userDataRemovalOverrides: [], applicationLeftoverPlan: plan,
            orphanedApplicationBundleIdentifiers: identifiers,
            orphanedApplicationItemPaths: Set(items.map(\.id))
        )
        await performCleanUp()
    }

    private(set) var cleanupOutcome: CleanupOutcome?

    struct CleanupCompletion: Identifiable {
        let id = UUID()
        let outcome: CleanupOutcome
    }

    var cleanupCompletion: CleanupCompletion?

    struct CleanupPlan {
        let id = UUID()
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

    func requestCleanUp(in filter: CleanupModel.ScanFilter) {
        guard canStart() else { return }
        let scope = cleanup.cleanupSelection(in: filter)
        let entries = cleanup.selectedEntries.filter { scope.contains($0.id) }
        let selectedIDs = Set(entries.map(\.id))
        let orphanedEntries = cleanup.selectedOrphanApplicationEntries.filter { scope.contains($0.id) }
        let orphanedIdentifiers = Set(orphanedEntries.compactMap(\.orphanedApplicationBundleIdentifier))
        let orphanedItemPaths = Set(orphanedEntries.flatMap(\.children).map(\.id))
        let orphanedPlan = cleanup.scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .applicationLeftoverPlan
        let plan = CleanupPlan(
            entries: entries,
            // Capture authorizations only for rows in this exact operation. The
            // service therefore cannot receive a broader capability than it needs.
            userDataRemovalOverrides: cleanup.userDataRemovalOverrides.intersection(selectedIDs),
            applicationLeftoverPlan: orphanedPlan,
            orphanedApplicationBundleIdentifiers: orphanedIdentifiers,
            orphanedApplicationItemPaths: orphanedItemPaths
        )
        guard !plan.entries.isEmpty || !plan.orphanedApplicationBundleIdentifiers.isEmpty
        else { return }
        var captured = plan
        captured.runningOwners = ApplicationRuntime.stillRunning(
            entries.flatMap {
                CleanupService.removalTargets(for: $0, removeProtectedAppData: false)
            }.compactMap(\.inUseBy)
        )
        pendingCleanUp = captured

        // Selected protected data follows the confirmation setting. Open apps still offer a quit action.
        if (settings?.confirmBeforeCleanup ?? SettingsStore.Defaults.confirmBeforeCleanup)
            || !captured.runningOwners.isEmpty {
            operations.activeSheet = .cleanUp
            measureCleanUpSaving(for: plan)
        } else {
            Task { await performCleanUp() }
        }
    }

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
            guard let self, self.operations.activeSheet == .cleanUp, self.pendingCleanUp?.id == plan.id else { return }
            self.pendingCleanUp?.freed = measurement
        }
    }

    private var cleanUpSavingTask: Task<Void, Never>?

    func cancelCleanUp() {
        cleanUpSavingTask?.cancel()
        cleanUpSavingTask = nil
        pendingCleanUp = nil
        operations.activeSheet = nil
    }

    func quitAppsForCleanup() async {
        guard canStart(), pendingCleanUp == nil else { return }
        cleanup.refreshCleanupRunningOwners()
        let owners = cleanup.cleanupRunningOwners
        guard !owners.isEmpty else { return }

        let stillOpen = await quit(owners)
        cleanup.clearInUse(of: owners.filter { !stillOpen.contains($0) })
        cleanup.refreshCleanupRunningOwners()
        operations.activity = nil

        if !stillOpen.isEmpty {
            let names = ListFormatter.localizedString(byJoining: stillOpen.map(\.name))
            operations.report(
                "Some Apps Are Still Open",
                "\(names) did not quit. Close these apps, then try Quit Apps again."
            )
        }
    }

    private func quit(_ owners: [FileEntry.RunningOwner]) async -> [FileEntry.RunningOwner] {
        operations.activity = .waitingForApplicationsToQuit(names: owners.map(\.name))
        for owner in owners {
            for process in ApplicationRuntime.processes(of: owner) { process.terminate() }
        }
        for _ in 0..<300 where !ApplicationRuntime.stillRunning(owners).isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ApplicationRuntime.stillRunning(owners)
    }

    private let cleanupService = CleanupService()

    func performCleanUp(quittingOwners: Bool = false) async {
        // The captured plan, never the live settings — see `CleanupPlan`.
        guard let plan = pendingCleanUp, operations.activity == nil else { return }
        cleanupCompletion = nil
        operations.removalCompletion = nil
        let completionDestination = destination()
        let presentation = OperationPresentationDuration()

        if quittingOwners, !plan.runningOwners.isEmpty {
            cleanUpSavingTask?.cancel()
            // The sheet goes first or the overlay that says what is happening
            // would sit underneath it.
            operations.activeSheet = nil
            let stragglers = await quit(plan.runningOwners)
            guard stragglers.isEmpty else {
                operations.activity = nil
                pendingCleanUp = nil
                let names = ListFormatter.localizedString(byJoining: stragglers.map(\.name))
                operations.report(
                    "Nothing Was Removed",
                    "\(names) did not quit, so Scolo stopped before touching anything. "
                        + "Quit it yourself and try Clean Up again."
                )
                return
            }
            cleanup.clearInUse(of: plan.runningOwners)
        }

        // The overlay says what is happening while it happens.
        operations.activity = .cleaningUp(itemCount: plan.itemCount, totalBytes: plan.totalBytes)
        let entries = plan.entries
        pendingCleanUp = nil
        operations.activeSheet = nil

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
            let registeredIdentifiers = ApplicationRuntime.registeredApplicationBundleIdentifiers(
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

        cleanupOutcome = outcome
        cleanup.applyRemoval(outcome, entries: entries)
        if !plan.orphanedApplicationBundleIdentifiers.isEmpty {
            refreshLeftovers?(plan.orphanedApplicationBundleIdentifiers)
        }

        if completionDestination == .uninstaller {
            // Refresh the list during progress, before the success animation starts.
            await waitForLeftovers?()
        }
        try? await presentation.wait()
        let deniedAppDataCount = outcome.permissionDenied.filter {
            ApplicationRuntime.isAppDataPath($0)
        }.count
        if deniedAppDataCount > 0 {
            // Its own alert, because it is the one failure with a remedy: the
            // permission is granted in System Settings, and the alert offers to
            // open it.
            operations.isShowingAppDataAccessAlert = true
        } else if completionDestination == .scanner, let unfinished = Self.cleanUpNotice(outcome) {
            operations.notice = unfinished
        }
        if completionDestination != .scanner {
            operations.completeTrashRemoval(outcome, in: completionDestination)
        }
        // Show success only when every requested item was moved.
        if destination() == .scanner, outcome.failed.isEmpty, outcome.removedCount > 0,
           outcome.trashedCount == outcome.removedCount, outcome.deletedCount == 0 {
            cleanupCompletion = CleanupCompletion(outcome: outcome)
        }
        if outcome.removedCount > 0 {
            cleanup.invalidateAfterRemoval()
        }
        operations.activity = nil
        await onRemoval?()
    }

    private static func cleanUpNotice(_ outcome: CleanupOutcome) -> OperationState.Notice? {
        guard !outcome.failed.isEmpty else { return nil }
        let count = outcome.failed.count
        let one = count == 1
        if outcome.removedCount == 0 {
            return OperationState.Notice(
                title: "Nothing Was Removed",
                message: one
                    ? "The selected item could not be removed. It is where it was."
                    : "None of the \(count) selected items could be removed. "
                        + "They are where they were."
            )
        }
        return OperationState.Notice(
            title: "Some Items Could Not Be Removed",
            message: "\(count) \(one ? "item" : "items") could not be removed; "
                + "the other \(outcome.removedCount) moved to the Trash."
        )
    }
}
