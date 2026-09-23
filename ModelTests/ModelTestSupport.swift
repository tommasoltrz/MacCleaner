import Foundation
import Testing
@testable import ScoloCore

@MainActor
func waitForModel(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("The model did not reach the expected state.")
            throw ModelTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

enum ModelTestError: Error { case timeout, scanFailed }

final class ModelTestStorage {
    let url: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "ScoloModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class ControlledCleanupScanner: CleanupScanning {
    var progress: [@Sendable (ScanProgress) -> Void] = []
    private var continuations: [CheckedContinuation<ScanResults, Error>] = []

    func scan(onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResults {
        progress.append(onProgress)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finish(_ results: ScanResults, at index: Int = 0) { continuations[index].resume(returning: results) }
    func fail(at index: Int = 0) { continuations[index].resume(throwing: ModelTestError.scanFailed) }
}

func scanResults(_ entries: [FileEntry], date: Date = Date()) -> ScanResults {
    ScanResults(categories: [.init(categoryID: .systemCaches, entries: entries)], startedAt: date, finishedAt: date)
}

actor FixtureFileScanner: FileDuplicateScanning {
    let results: FileDuplicateResults
    private(set) var scans = 0

    init(_ results: FileDuplicateResults) { self.results = results }

    func scan(
        roots: [URL], options: FileDuplicateService.Options,
        excludedPaths: [String], excludedPatterns: [String],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) async throws -> FileDuplicateResults {
        scans += 1
        return results
    }
}

actor FixturePhotoLibrary: PhotoLibraryProviding {
    let assets: [PhotoAsset]
    private(set) var deletedIDs: [String] = []

    init() {
        assets = ["first", "second", "third"].map {
            PhotoAsset(id: $0, creationDate: Date(timeIntervalSince1970: 100), pixelWidth: 100, pixelHeight: 100)
        }
    }

    func authorize() async -> PhotoLibraryAccess { .authorized }
    func fetchAssets() async throws -> [PhotoAsset] { assets }
    func fingerprint(assetID: String) async -> PhotoFingerprint? { .init(vector: [0, 0]) }
    func delete(assetIDs: [String]) async throws { deletedIDs = assetIDs }
}
