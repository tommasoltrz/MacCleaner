import AppKit
import Observation
import ScoloCore

/// Owns application plans and uninstall operations.
@MainActor
@Observable
final class UninstallerModel {
    let library: ApplicationLibraryModel

    @ObservationIgnored private let settings: SettingsStore?

    let operations: OperationState

    @ObservationIgnored var canStart: () -> Bool = { true }

    @ObservationIgnored var onReview: (() -> Void)?

    @ObservationIgnored var onRemoval: (() async -> Void)?

    private let cleanupService = CleanupService()

    init(settings: SettingsStore? = nil, operations: OperationState) {
        self.settings = settings
        self.library = ApplicationLibraryModel(settings: settings)
        self.operations = operations
    }

    private var keepReceipt: Bool { settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt }

    var uninstallerRemoveLabel: String {
        switch uninstallerTab {
        case .installed:
            let count = library.selectedApplicationIDs.count
            guard count > 0 else { return "Move to Trash" }
            return "Move to Trash (\(count) \(count == 1 ? "app" : "apps"))"
        case .leftovers:
            return "Move Leftovers to Trash"
        }
    }

    private let appUninstallPlanner = AppUninstallPlanner()

    @ObservationIgnored private var appUninstallTask: Task<Void, Never>?

    @ObservationIgnored private var appUninstallPlanningID: UUID?

    var appUninstallPlan: AppUninstallPlan?

    private(set) var isPlanningAppUninstall = false

    private(set) var appUninstallPlanningURL: URL?

    private(set) var appUninstallError: String?

    private(set) var appUninstallOutcome: CleanupOutcome?

    private(set) var lastUninstalledApplicationName: String?

    struct PendingAppUninstall {
        let plan: AppUninstallPlan

        var itemCount: Int { plan.items.count }
        var totalBytes: Int64 { plan.totalBytes }
        var protectedDataCount: Int { plan.protectedItems.count }
        var isApplicationOnly: Bool { plan.isApplicationOnly }
    }

    private(set) var pendingAppUninstall: PendingAppUninstall?

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
        onReview?()
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
            let presentation = OperationPresentationDuration()
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
                guard !Task.isCancelled, self.appUninstallPlanningID == planningID else { return }
                self.appUninstallError = error.localizedDescription
            }
            try? await presentation.wait()
        }
    }

    func resetAppUninstall() {
        guard !operations.isUninstallingApp else { return }
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

    func requestAppUninstall() {
        guard canStart(), let plan = appUninstallPlan, plan.managedPackage == nil else { return }
        pendingAppUninstall = PendingAppUninstall(plan: plan)
        Task { await performAppUninstall() }
    }

    private enum UninstallAttempt {
        case stillRunning
        case interrupted
        case finished(CleanupOutcome)
    }

    private func attemptUninstall(_ plan: AppUninstallPlan) async -> UninstallAttempt {
        let applicationName = plan.applicationName
        let applicationOnly = plan.isApplicationOnly
        operations.activity = .uninstalling(
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
            operations.activity = .uninstalling(
                applicationName: applicationName, applicationOnly: applicationOnly, waitingToQuit: true
            )
            for application in running { application.terminate() }
        }
        for _ in 0..<30 where !matchingRunningApplications().isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !matchingRunningApplications().isEmpty { return .stillRunning }
        operations.activity = .uninstalling(
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
        guard let request = pendingAppUninstall, operations.activity == nil else { return }
        pendingAppUninstall = nil
        operations.activeSheet = nil
        appUninstallError = nil
        let presentation = OperationPresentationDuration()

        let outcome: CleanupOutcome
        switch await attemptUninstall(request.plan) {
        case .stillRunning:
            operations.activity = nil
            appUninstallError = "\(request.plan.applicationName) is still running. "
                + "Quit it and try again; no files were removed."
            return
        case .interrupted:
            operations.activity = nil
            appUninstallError = "The uninstall was interrupted. Review the application and try again."
            return
        case .finished(let finished):
            outcome = finished
        }

        appUninstallOutcome = outcome
        lastUninstalledApplicationName = request.plan.applicationName
        appUninstallPlan = nil
        library.didUninstall(request.plan.applicationURL.path)

        let applicationFailed = outcome.failed.contains(request.plan.applicationURL.path)
        if applicationFailed {
            let relatedFilesMessage = request.plan.isApplicationOnly
                ? "" : " No related files were removed."
            appUninstallError = "\(request.plan.applicationName) could not be moved to the Trash."
                + relatedFilesMessage
        }
        // Everything else this used to say is on the done page: what was removed,
        // and how many related items remain on disk.

        try? await presentation.wait()
        operations.activity = nil
        await onRemoval?()
    }

    enum UninstallerTab: String, CaseIterable {
        case installed = "Installed"
        case leftovers = "Leftovers"
    }

    var uninstallerTab: UninstallerTab = .installed

    var isShowingUninstallerLibrary: Bool {
        appUninstallPlan == nil && batchUninstallReview == nil
            && appUninstallOutcome == nil && batchUninstallOutcome == nil
            && !isPlanningAppUninstall
    }

    struct SetAsideApplication {
        let name: String
        let reason: String
    }

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

    private(set) var appUninstallPlanningDetail: String?

    private(set) var pendingBatchUninstall: BatchUninstallReview?

    func moveSelectedApplicationsToTrash() {
        let selected = (library.installedApplications ?? [])
            .filter { library.selectedApplicationIDs.contains($0.id) }
        guard !selected.isEmpty, canStart(), !isPlanningAppUninstall else { return }

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
            self.pendingBatchUninstall = BatchUninstallReview(plans: plans, setAside: setAside)
            self.isPlanningAppUninstall = false
            self.appUninstallPlanningDetail = nil
            self.appUninstallPlanningID = nil
            self.appUninstallTask = nil
            await self.performBatchUninstall()
        }
    }

    func requestBatchUninstall() {
        guard canStart(), let review = batchUninstallReview, !review.plans.isEmpty else { return }
        pendingBatchUninstall = review
        Task { await performBatchUninstall() }
    }

    func performBatchUninstall() async {
        guard let request = pendingBatchUninstall, operations.activity == nil else { return }
        pendingBatchUninstall = nil
        operations.activeSheet = nil
        appUninstallError = nil
        let presentation = OperationPresentationDuration()

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
                    library.didUninstall(plan.applicationURL.path)
                }
            }
        }

        batchUninstallReview = nil
        // The done page lists what was uninstalled and what is still installed.
        batchUninstallOutcome = result

        try? await presentation.wait()
        operations.activity = nil
        await onRemoval?()
    }
}
