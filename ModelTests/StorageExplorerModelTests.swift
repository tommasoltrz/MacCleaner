import Foundation
import Testing
import ScoloCore

private actor ControlledStorageScanner: StorageExplorerScanning {
    private var pending: [CheckedContinuation<StorageExplorerSnapshot, Error>] = []
    var count: Int { pending.count }
    private var updates: [(@Sendable (StorageExplorerScanUpdate) -> Void)?] = []

    func scan(
        directory: URL, excludedPaths: [String], excludedPatterns: [String],
        progress: (@Sendable (SizeMeasurement) -> Void)?,
        onUpdate: (@Sendable (StorageExplorerScanUpdate) -> Void)?
    ) async throws -> StorageExplorerSnapshot {
        updates.append(onUpdate)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func reviewSelection(
        _ items: [StorageExplorerItem], in directory: URL,
        excludedPaths: [String], excludedPatterns: [String]
    ) async throws -> StorageExplorerSelectionReview {
        throw ModelTestError.scanFailed
    }

    func send(_ update: StorageExplorerScanUpdate, at index: Int) { updates[index]?(update) }

    func finish(_ snapshot: StorageExplorerSnapshot, at index: Int) { pending[index].resume(returning: snapshot) }
    func fail(at index: Int) { pending[index].resume(throwing: ModelTestError.scanFailed) }

    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while pending.count < count {
            guard ContinuousClock.now < deadline else { throw ModelTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("Storage Explorer model")
@MainActor
struct StorageExplorerModelTests {
    private let root = URL(fileURLWithPath: "/model-cache-fixture")

    private func snapshot(_ name: String, bytes: Int64) -> StorageExplorerSnapshot {
        let directory = root.appendingPathComponent(name)
        return StorageExplorerSnapshot(
            directory: directory,
            items: [StorageExplorerItem(
                url: directory.appendingPathComponent("file"), kind: .file,
                allocatedBytes: bytes, fileCount: 1, identity: name + "-file"
            )], allocatedBytes: bytes, fileCount: 1, unreadableCount: 0
        )
    }

    @Test("location shortcuts reuse cached folders and explicit refresh scans again")
    func locationCache() async throws {
        let scanner = ControlledStorageScanner()
        let model = StorageExplorerModel(service: scanner)
        let original = snapshot("First", bytes: 100)
        model.selectLocation(original.directory)
        try await scanner.waitForRequests(1)
        await scanner.finish(original, at: 0)
        try await waitForModel { !model.isLoading }
        model.selectLocation(original.directory)
        #expect(!model.isLoading)
        #expect(model.snapshot == original)
        #expect(await scanner.count == 1)
        model.refresh()
        try await scanner.waitForRequests(2)
        await scanner.finish(snapshot("First", bytes: 120), at: 1)
        try await waitForModel { !model.isLoading }
        #expect(model.snapshot?.allocatedBytes == 120)
    }

    @Test("partial results cannot be removed and retained folders open without a scan")
    func progressiveNavigation() async throws {
        let scanner = ControlledStorageScanner()
        let model = StorageExplorerModel(service: scanner)
        let parent = snapshot("First", bytes: 100)
        let nested = snapshot("First/Nested", bytes: 100)
        model.selectLocation(parent.directory)
        try await scanner.waitForRequests(1)
        var partial = parent
        partial.isPartial = true
        await scanner.send(.partial(partial), at: 0)
        try await waitForModel { model.snapshot?.isPartial == true }
        #expect(model.isLoading)
        model.selection = [partial.items[0].id]
        #expect(!model.canRemoveSelection)
        model.cancel()
        #expect(model.snapshot?.isPartial == true)
        #expect(!model.wasCancelled)
        #expect(!model.canRemoveSelection)
        await scanner.finish(parent, at: 0)

        model.selectLocation(parent.directory)
        try await scanner.waitForRequests(2)
        await scanner.send(.retained([nested]), at: 1)
        await scanner.finish(parent, at: 1)
        try await waitForModel { !model.isLoading }
        model.navigate(to: nested.directory)
        #expect(!model.isLoading)
        #expect(model.snapshot == nested)
        #expect(await scanner.count == 2)
        await scanner.send(.partial(partial), at: 1)
        await Task.yield()
        #expect(model.snapshot == nested)
    }

    @Test("cached navigation stays immediate and rejects a late background result")
    func cachedNavigation() async throws {
        let scanner = ControlledStorageScanner()
        let model = StorageExplorerModel(service: scanner)
        let first = snapshot("First", bytes: 100)
        let second = snapshot("Second", bytes: 200)
        model.navigate(to: first.directory)
        try await scanner.waitForRequests(1)
        await scanner.finish(first, at: 0)
        try await waitForModel { !model.isLoading }
        model.navigate(to: second.directory)
        try await scanner.waitForRequests(2)
        await scanner.finish(second, at: 1)
        try await waitForModel { !model.isLoading }
        model.invalidateCache()

        model.goBack()
        #expect(!model.isLoading)
        #expect(model.isRefreshing)
        #expect(model.snapshot?.allocatedBytes == 100)
        try await scanner.waitForRequests(3)
        model.goForward()
        #expect(!model.isLoading)
        #expect(model.snapshot?.directory == second.directory)
        try await scanner.waitForRequests(4)
        await scanner.finish(snapshot("First", bytes: 999), at: 2)
        await scanner.finish(snapshot("Second", bytes: 250), at: 3)
        try await waitForModel { !model.isRefreshing }
        #expect(model.snapshot?.directory == second.directory)
        #expect(model.snapshot?.allocatedBytes == 250)
        #expect(model.snapshot?.isEstimated == false)
    }

    @Test("a failed or stopped update preserves the visible folder")
    func failedRefresh() async throws {
        let scanner = ControlledStorageScanner()
        let model = StorageExplorerModel(service: scanner)
        let original = snapshot("First", bytes: 100)
        model.navigate(to: original.directory)
        try await scanner.waitForRequests(1)
        await scanner.finish(original, at: 0)
        try await waitForModel { !model.isLoading }
        model.selection = [original.items[0].id]
        model.invalidateCache()
        model.refreshEstimatedSnapshot()
        try await scanner.waitForRequests(2)
        await scanner.fail(at: 1)
        try await waitForModel { !model.isRefreshing }
        #expect(model.snapshot?.allocatedBytes == 100)
        #expect(model.snapshot?.isEstimated == true)
        #expect(model.refreshFailed)
        #expect(model.error == nil)
        #expect(!model.wasCancelled)
        #expect(model.selection == [original.items[0].id])

        model.refreshEstimatedSnapshot()
        try await scanner.waitForRequests(3)
        model.cancel()
        await scanner.finish(snapshot("First", bytes: 500), at: 2)
        #expect(!model.wasCancelled)
        #expect(!model.isRefreshing)
        #expect(model.snapshot?.allocatedBytes == 100)
    }

    @Test("Trash selection is rejected without a selection loop")
    func trashSelection() {
        let model = StorageExplorerModel()
        var contents = snapshot("First", bytes: 100)
        contents.items[0].protectionReason = .trash
        model.snapshot = contents
        model.selection = [contents.items[0].id]
        #expect(model.selection.isEmpty)
        model.selection = []
        #expect(!model.canRemoveSelection)
    }

    @Test("successful removals update the visible cache before navigation")
    func removalUpdatesSnapshot() async throws {
        let scanner = ControlledStorageScanner()
        let model = StorageExplorerModel(service: scanner)
        let original = snapshot("First", bytes: 100)
        model.navigate(to: original.directory)
        try await scanner.waitForRequests(1)
        await scanner.finish(original, at: 0)
        try await waitForModel { !model.isLoading }
        model.selection = [original.items[0].id]
        var outcome = CleanupOutcome(removedBytes: 100, removedCount: 1, trashedCount: 1)
        outcome.removedRecords = [RemovalRecord(
            timestamp: Date(), originalPath: original.items[0].url.path, bytes: 100,
            disposition: .trashed, trashedPath: root.appendingPathComponent(".Trash/file").path
        )]
        model.applyRemovalOutcome(outcome, items: original.items)
        #expect(model.snapshot?.items.isEmpty == true)
        #expect(model.snapshot?.allocatedBytes == 0)
        #expect(model.snapshot?.isEstimated == true)
        #expect(model.selection.isEmpty)
        #expect(!model.isLoading)
    }
}
