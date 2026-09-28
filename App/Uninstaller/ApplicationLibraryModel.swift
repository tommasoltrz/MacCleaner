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

    private(set) var webApplications: [InstalledWebApplication]?
    var webAppError: String?

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
            let registered = ApplicationRuntime.registeredApplicationBundleIdentifiers(
                for: candidates.identifiers, stagedApplicationRoots: candidates.stagedApplicationRoots
            )
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
        webAppError = nil
        installedApplicationsTask?.cancel()
        let settings = settings
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        let planner = appUninstallPlanner
        installedApplicationsTask = Task { [weak self] in
            let (applications, webApplications) = await Task.detached(priority: .userInitiated) {
                (planner.installedApplications(context: context), planner.installedWebApplications(context: context))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.installedApplications = applications
            self.webApplications = webApplications
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

    struct WebAppBrowser: Identifiable {
        let id: String
        let name: String
        let url: URL
        let controlsURL: String
    }

    var webAppBrowsers: [WebAppBrowser] {
        [
            ("com.google.Chrome", "chrome://apps"),
            ("com.google.Chrome.beta", "chrome://apps"),
            ("com.google.Chrome.dev", "chrome://apps"),
            ("com.google.Chrome.canary", "chrome://apps"),
            ("org.chromium.Chromium", "chrome://apps"),
            ("com.microsoft.edgemac", "edge://apps"),
            ("com.brave.Browser", "chrome://apps")
        ].compactMap { identifier, controls in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            return WebAppBrowser(id: identifier, name: url.deletingPathExtension().lastPathComponent,
                                 url: url, controlsURL: controls)
        }
    }

    func openWebAppControls(in browser: WebAppBrowser) {
        webAppError = nil
        guard let url = URL(string: browser.controlsURL) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser.url,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.webAppError = "The browser could not open its removal controls."
            }
        }
    }

    func openWebAppControls(_ application: InstalledWebApplication) {
        webAppError = nil
        guard let identifier = application.browserIdentifier,
              let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              let executable = Bundle(url: browser)?.executableURL,
              let arguments = application.removalArguments else {
            webAppError = "The browser or profile is unavailable. Open the web app to remove it from its menu."
            return
        }
        openWebAppControls(executable: executable, arguments: arguments)
    }

    private func openWebAppControls(executable: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor [weak self] in
                self?.webAppError = "The browser could not open its removal controls."
            }
        }
        do { try process.run() }
        catch { webAppError = "The browser could not open its removal controls." }
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
