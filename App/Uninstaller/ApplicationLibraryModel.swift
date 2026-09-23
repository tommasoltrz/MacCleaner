import AppKit
import Observation
import ScoloCore

/// Owns installed applications, leftover files, and library selection.
@MainActor
@Observable
final class ApplicationLibraryModel {
    @ObservationIgnored private let settings: SettingsStore?
    private let appUninstallPlanner = AppUninstallPlanner()

    init(settings: SettingsStore? = nil) { self.settings = settings }

    private(set) var installedApplications: [InstalledApplication]?

    private(set) var installedApplicationBytes: [String: Int64] = [:]

    private(set) var installedApplicationsMeasured = false

    @ObservationIgnored private var installedApplicationsTask: Task<Void, Never>?

    private(set) var applicationLeftovers: OrphanedAppLeftoverPlan?

    private(set) var isLoadingApplicationLeftovers = false

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
            let presentation = OperationPresentationDuration()
            // One candidate scan, resolved once, handed to the planner whole — the
            // same order the junk scan uses, for the same reason: scanning twice
            // lets an identifier appear between the passes with no owner check.
            let candidates = await Task.detached(priority: .userInitiated) {
                planner.scanCandidates()
            }.value
            guard self != nil, !Task.isCancelled else { return }
            let registered = ApplicationRuntime.registeredApplicationBundleIdentifiers(for: candidates.identifiers)
            let plan = try? await planner.plan(
                context: context,
                registeredApplicationBundleIdentifiers: registered,
                candidates: candidates
            )
            try? await presentation.wait()
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

    var selectedApplicationBytes: Int64? {
        var total: Int64 = 0
        for id in selectedApplicationIDs {
            guard let bytes = installedApplicationBytes[id] else { return nil }
            total += bytes
        }
        return total
    }

    private(set) var selectedApplicationIDs: Set<String> = []

    func toggleApplicationSelection(_ application: InstalledApplication) {
        if selectedApplicationIDs.remove(application.id) == nil {
            selectedApplicationIDs.insert(application.id)
        }
    }

    func clearApplicationSelection() { selectedApplicationIDs.removeAll() }

    func waitForLeftovers() async { await applicationLeftoversTask?.value }

    private let orphanedAppLeftoverPlanner = OrphanedAppLeftoverPlanner()

    func didUninstall(_ path: String) { selectedApplicationIDs.remove(path) }
}
