import Foundation
import Observation
import ScoloCore

/// Owns cleanup history loading.
@MainActor
@Observable
final class HistoryModel {
    private let cleanupHistoryService = CleanupHistoryService()

    private(set) var cleanupHistory: CleanupHistorySummary?

    private(set) var isLoadingCleanupHistory = false

    func loadCleanupHistory() async {
        guard !isLoadingCleanupHistory else { return }
        isLoadingCleanupHistory = true
        let service = cleanupHistoryService
        cleanupHistory = await Task.detached {
            service.summary()
        }.value
        isLoadingCleanupHistory = false
    }
}
