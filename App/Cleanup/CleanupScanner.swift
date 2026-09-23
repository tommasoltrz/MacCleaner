import AppKit
import ScoloCore

@MainActor
protocol CleanupScanning {
    func scan(onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResults
}

/// Builds a scan context from settings and current application owners.
@MainActor
final class CleanupScanner: CleanupScanning {
    private let settings: SettingsStore?
    private let coordinator: ScanCoordinator
    private let orphanedAppLeftoverPlanner = OrphanedAppLeftoverPlanner()

    init(settings: SettingsStore? = nil, coordinator: ScanCoordinator = .standard()) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func scan(onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResults {
        // Ground truth for app protection: what is running right now.
        // NSWorkspace is AppKit, so the set is built here and handed to Core.
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
        )
        // The same truth with names attached, so a cache can say whose it
        // is — see `FileEntry.inUseBy`.
        let runningOwners = ApplicationRuntime.currentRunningOwners()
        // The preferences' whole reason to exist flows in here: exclusions
        // and disabled categories were all collected and then ignored until this call passed them.
        let settings = settings
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
        if enabled.map({ !$0.isDisjoint(with: [.applicationLeftovers, .sharedData]) }) ?? true {
            let planner = orphanedAppLeftoverPlanner
            let candidates = await Task.detached { planner.scanCandidates() }.value
            leftoverCandidates = candidates
            registeredIdentifiers = ApplicationRuntime.registeredApplicationBundleIdentifiers(
                for: candidates.identifiers, stagedApplicationRoots: candidates.stagedApplicationRoots
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
        try Task.checkCancellation()
        return try await coordinator.scan(enabled: enabled, context: context, onProgress: onProgress)
    }
}
