import Foundation
import Testing
@testable import ScoloCore

@Suite("Cleanup model")
@MainActor
struct CleanupModelTests {
    @Test("Cleanup detects an owner started after the plan was captured")
    func newlyStartedOwner() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let cleanup = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let url = storage.url.appendingPathComponent("cache")
        try Data(repeating: 1, count: 4096).write(to: url)
        let cache = FileEntry(url: url, kind: .cache, allocatedBytes: 4096, isRegenerable: true,
                              ownerRules: [.bundleIdentifier("com.example.app")])
        cleanup.startScan()
        try await waitForModel { scanner.progress.count == 1 }
        scanner.finish(scanResults([cache]))
        try await waitForModel { !cleanup.isScanning }
        let settings = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = true
        settings.keepReceipt = false
        let operations = OperationState()
        let removal = CleanupRemovalModel(settings: settings, cleanup: cleanup, operations: operations)
        removal.runningOwners = { [] }
        removal.requestCleanUp(in: .safeToRemove)
        #expect(removal.pendingCleanUp?.runningOwners.isEmpty == true)
        let owner = FileEntry.RunningOwner(name: "Example", bundleIdentifier: "com.example.app", bundlePath: "/Example.app")
        removal.runningOwners = { [owner] }
        await removal.performCleanUp()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(removal.cleanupOutcome?.inUse == [url.path: "Example"])
        #expect(removal.cleanupCompletion == nil)
        #expect(operations.notice?.message.contains("Example") == true)
        #expect(operations.activity == nil)

        removal.requestCleanUp(in: .safeToRemove)
        #expect(removal.pendingCleanUp?.runningOwners == [owner])
        removal.cancelCleanUp()
    }

    @Test("A nested helper resolves to its enclosing application without guessing unrelated services")
    func helperOwnership() throws {
        let storage = try ModelTestStorage()
        let app = storage.url.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app", "CFBundleName": "Example", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let helper = app.appendingPathComponent("Contents/Frameworks/Example Helper.app")
        let owner = ApplicationRuntime.owner(bundleURL: helper, identifier: "com.example.helper", name: "Example Helper")
        #expect(owner.bundlePath == app.path)
        #expect(owner.bundleIdentifier == "com.example.app")
        let cache = FileEntry(url: storage.url.appendingPathComponent("cache"), kind: .cache,
                              allocatedBytes: 1, ownerRules: [.bundleIdentifier("com.example.app")])
        #expect(ScanContext(runningApplications: [owner]).runningOwner(for: cache) == owner)
        let unrelated = ApplicationRuntime.owner(
            bundleURL: storage.url.appendingPathComponent("Independent.app"),
            identifier: "org.independent.service", name: "Independent"
        )
        #expect(ScanContext(runningApplications: [unrelated]).runningOwner(for: cache) == nil)
    }

    @Test("Verified leftovers are selected while AI saved data stays locked")
    func leftoverAndAISelection() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let model = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let item = FileEntry(url: storage.url.appendingPathComponent("old-data"), kind: .folder, allocatedBytes: 2_000_000)
        let leftover = FileEntry(url: item.url, kind: .folder, allocatedBytes: 0,
                                 removalAction: .orphanedApplication(bundleIdentifier: "com.example.removed"), children: [item])
        let saved = FileEntry(url: storage.url.appendingPathComponent("sessions"), kind: .folder,
                              allocatedBytes: 4_000_000, protectionReason: .userData, userDataRemovalWarning: "Saved sessions.")
        model.startScan()
        try await waitForModel { scanner.progress.count == 1 }
        scanner.finish(ScanResults(categories: [
            .init(categoryID: .applicationLeftovers, entries: [leftover]),
            .init(categoryID: .aiTools, entries: [saved])
        ], startedAt: Date(), finishedAt: Date()))
        try await waitForModel { !model.isScanning }
        #expect(model.scannerSelection == [leftover.id])
        #expect(model.selectedOrphanApplicationEntries.map(\.id) == [leftover.id])
        #expect(model.userDataRemovalOverrides.isEmpty)
    }

    @Test("AI Tools starts on and preserves an explicit setting")
    func aiToolsDefaults() throws {
        let storage = try ModelTestStorage()
        let settings = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(settings.isEnabled(.aiTools))
        settings.setEnabled(false, for: .aiTools)
        let restored = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(!restored.isEnabled(.aiTools))
        restored.resetToDefaults()
        #expect(restored.isEnabled(.aiTools))
    }

    @Test("Cancellation rejects late results and progress")
    func cancelledScanCannotPublish() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let model = CleanupModel(scanner: scanner, defaults: storage.defaults)
        model.startScan()
        try await waitForModel { scanner.progress.count == 1 }
        model.cancelScan()
        scanner.finish(scanResults([]))
        try await waitForModel { !model.isScanning }
        #expect(model.scanResults == nil)
        #expect(model.lastScanFinishedAt == nil)

        model.startScan()
        try await waitForModel { scanner.progress.count == 2 }
        scanner.progress[0](.init(percent: 99, completedCategories: 1, totalCategories: 1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.scanProgress == 0)
        scanner.finish(scanResults([]), at: 1)
        try await waitForModel { !model.isScanning }
        #expect(model.scanResults != nil)
    }

    @Test("A new scan clears overrides and seeds only safe items")
    func scanSelectionLifecycle() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let model = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let safe = FileEntry(url: storage.url.appendingPathComponent("cache"), kind: .cache,
                             allocatedBytes: 2_000_000, isRegenerable: true)
        let protected = FileEntry(url: storage.url.appendingPathComponent("data"), kind: .folder,
                                  allocatedBytes: 4_000_000, protectionReason: .userData)
        model.scannerSelection = [protected.id]
        model.userDataRemovalOverrides = [protected.id]
        model.startScan()
        #expect(model.userDataRemovalOverrides.isEmpty)
        #expect(!model.scannerSelection.contains(protected.id))
        try await waitForModel { scanner.progress.count == 1 }
        scanner.finish(scanResults([safe, protected]))
        try await waitForModel { !model.isScanning }
        #expect(model.scannerSelection == [safe.id])
        model.deselectAll()
        model.seedSafeToRemoveSelection()
        #expect(model.scannerSelection.isEmpty)
        model.invalidateAfterRemoval()
        #expect(model.needsInitialScan)
        #expect(model.scanResults == nil)
    }

    @Test("A failed scan releases the busy state")
    func failureReleasesScan() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let model = CleanupModel(scanner: scanner, defaults: storage.defaults)
        var failures = 0
        model.onFailure = { _, _ in failures += 1 }
        model.startScan()
        try await waitForModel { scanner.progress.count == 1 }
        scanner.fail()
        try await waitForModel { !model.isScanning }
        #expect(failures == 1)
        #expect(model.scanResults == nil)
    }

    @Test("The app blocks other scans until cleanup cancellation finishes")
    func sharedOperationGuard() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let cleanup = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let app = AppModel(cleanup: cleanup, startsScheduler: false)
        app.startScan(refreshOverview: false)
        try await waitForModel { scanner.progress.count == 1 }
        #expect(app.isBusyWithDisk)
        app.startPhotoSweep()
        #expect(!app.photoDuplicates.isScanning)
        app.startFileDuplicateScan(roots: [storage.url])
        #expect(!app.fileDuplicates.isScanningDuplicateFiles)
        cleanup.cancelScan()
        scanner.finish(scanResults([]))
        try await waitForModel { !app.isBusyWithDisk }
        #expect(app.operations.notice == nil)
    }

    @Test("Cleanup plans keep only the reviewed overrides")
    func capturedPlanScope() async throws {
        let storage = try ModelTestStorage()
        let scanner = ControlledCleanupScanner()
        let cleanup = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let item = FileEntry(url: storage.url.appendingPathComponent("cache"), kind: .cache,
                             allocatedBytes: 2_000_000, isRegenerable: true)
        cleanup.startScan()
        try await waitForModel { scanner.progress.count == 1 }
        scanner.finish(scanResults([item]))
        try await waitForModel { !cleanup.isScanning }
        let settings = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = true
        let operations = OperationState()
        let removal = CleanupRemovalModel(settings: settings, cleanup: cleanup, operations: operations)
        cleanup.userDataRemovalOverrides = [item.id, "/unknown"]
        removal.requestCleanUp(in: .safeToRemove)
        let plan = try #require(removal.pendingCleanUp)
        #expect(plan.userDataRemovalOverrides == [item.id])
        cleanup.deselectAll()
        #expect(removal.pendingCleanUp?.entries.map(\.id) == [item.id])
        removal.cancelCleanUp()
        #expect(removal.pendingCleanUp == nil)
        #expect(operations.activeSheet == nil)
    }
}
