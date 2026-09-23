import Foundation
import Testing
@testable import ScoloCore

@Suite("Operation presentation")
@MainActor
struct OperationStateTests {
    @Test("Partial removal remains visible and cannot report success")
    func partialRemovalDoesNotDismiss() {
        let operations = OperationState()
        operations.activity = .removingDuplicateFiles(itemCount: 2, totalBytes: 500)
        operations.completeTrashRemoval(
            CleanupOutcome(removedBytes: 250, removedCount: 1, failed: ["copy"], trashedCount: 1), in: .duplicates
        )
        #expect(operations.activity != nil)
        #expect(operations.removalCompletion?.isSuccess == false)
        #expect(operations.removalCompletion?.dismissesAutomatically == false)
        operations.activity = nil
        #expect(operations.removalCompletion != nil)
    }

    @Test("A delayed dismissal cannot clear another completion")
    func dismissChecksIdentity() async throws {
        let app = AppModel(startsScheduler: false)
        app.view = .uninstaller
        app.operations.completeTrashRemoval(
            CleanupOutcome(removedBytes: 1, removedCount: 1, trashedCount: 1), in: .uninstaller
        )
        let first = try #require(app.operations.removalCompletion?.id)
        let dismiss = Task { await app.automaticallyDismissRemovalCompletion(first) }
        await Task.yield()
        app.operations.completeTrashRemoval(
            CleanupOutcome(removedBytes: 2, removedCount: 2, trashedCount: 2), in: .uninstaller
        )
        let second = app.operations.removalCompletion?.id
        await dismiss.value
        #expect(app.operations.removalCompletion?.id == second)
    }

    @Test("Navigation clears the previous completion")
    func navigationClearsCompletion() {
        let app = AppModel(startsScheduler: false)
        app.operations.completeTrashRemoval(
            CleanupOutcome(removedBytes: 1, removedCount: 1, trashedCount: 1), in: .duplicates
        )
        app.view = .dashboard
        #expect(app.operations.removalCompletion == nil)
    }
}
