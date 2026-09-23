import Foundation
import Testing
@testable import ScoloCore

@Suite("Cleanup model")
@MainActor
struct CleanupModelTests {
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
