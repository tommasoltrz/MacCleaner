import Foundation

/// Keeps operation progress visible for one second. Cancellation ends the wait immediately.
struct OperationPresentationDuration: Sendable {
    private let deadline = ContinuousClock.now.advanced(by: .seconds(1))

    func wait() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { return }
        try await ContinuousClock().sleep(until: deadline)
    }
}
