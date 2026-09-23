import Foundation
import ScoloCore

/// Supports scan substitution without access to user folders.
protocol FileDuplicateScanning: Sendable {
    func scan(
        roots: [URL], options: FileDuplicateService.Options,
        excludedPaths: [String], excludedPatterns: [String],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) async throws -> FileDuplicateResults
}

extension FileDuplicateService: FileDuplicateScanning {}
