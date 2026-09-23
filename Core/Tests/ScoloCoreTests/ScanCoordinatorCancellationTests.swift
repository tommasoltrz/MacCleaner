import Foundation
import Testing
@testable import ScoloCore

@Suite("Scan coordinator cancellation")
struct ScanCoordinatorCancellationTests {
    private actor Scanner: CategoryScanner {
        nonisolated let id = CategoryID.systemCaches
        private(set) var calls = 0
        private(set) var cancellations = 0

        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            calls += 1
            guard calls == 1 else { return .init(categoryID: id, entries: []) }
            do {
                try await Task.sleep(for: .seconds(30))
                return .init(categoryID: id, entries: [])
            } catch {
                cancellations += 1
                throw error
            }
        }
    }

    @Test("Cancelling the caller stops category work and permits the next scan")
    func callerCancellation() async throws {
        let scanner = Scanner()
        let coordinator = ScanCoordinator(scanners: [scanner])
        let task = Task { try await coordinator.scan() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await scanner.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await scanner.calls == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("The cancelled scan returned results.")
        } catch is CancellationError {
        }
        #expect(await scanner.cancellations == 1)
        #expect(await coordinator.isScanning == false)
        let results = try await coordinator.scan()
        #expect(results.categories.count == 1)
        #expect(await scanner.calls == 2)
    }
}
