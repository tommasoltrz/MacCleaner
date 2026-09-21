import Foundation
import Testing
@testable import ScoloCore

/// Changing how alike "alike" means must not cost a sweep.
///
/// The expensive half of a sweep — the library fetch and the fingerprinting, which
/// goes to iCloud for anything without a local thumbnail — produces the same result
/// whatever the threshold is. Only the comparing phase depends on it. So the setting
/// is a control on the results page rather than a reason to start over, and these
/// tests pin the two claims that makes: that a regroup really does change the
/// grouping, and that it really does not touch the library.
@Suite("Regrouping at a new threshold needs no sweep")
struct PhotoRegroupTests {

    /// Counts what it is asked for, so a test can assert an absence of work rather
    /// than only the presence of a result.
    private final class FakeLibrary: PhotoLibraryProviding, @unchecked Sendable {
        let assets: [PhotoAsset]
        let prints: [String: PhotoFingerprint]
        private(set) var fetchCount = 0
        private(set) var fingerprintCount = 0

        init(assets: [PhotoAsset], prints: [String: PhotoFingerprint]) {
            self.assets = assets
            self.prints = prints
        }

        func authorize() async -> PhotoLibraryAccess { .authorized }
        func fetchAssets() async throws -> [PhotoAsset] {
            fetchCount += 1
            return assets
        }
        func fingerprint(assetID: String) async -> PhotoFingerprint? {
            fingerprintCount += 1
            return prints[assetID]
        }
        func delete(assetIDs: [String]) async throws {}
    }

    private func asset(_ id: String, seconds: TimeInterval, width: Int = 4032) -> PhotoAsset {
        PhotoAsset(
            id: id,
            filename: "\(id).heic",
            creationDate: Date(timeIntervalSince1970: seconds),
            pixelWidth: width,
            pixelHeight: 3024,
            mediaType: .image,
            duration: 0,
            burstIdentifier: nil,
            representsBurst: false,
            isFavorite: false,
            isHidden: false,
            hasAdjustments: false
        )
    }

    /// Two photographs 0.3 apart: inside `.standard` (0.35), outside `.strict` (0.25).
    private func makeService() throws -> (PhotoDuplicateService, FakeLibrary, URL) {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000)]
        let prints: [String: PhotoFingerprint] = [
            "a": PhotoFingerprint(vector: [0, 0, 0]),
            "b": PhotoFingerprint(vector: [0.3, 0, 0])
        ]
        let library = FakeLibrary(assets: assets, prints: prints)
        // Never the real Application Support folder: a sweep saves the cache, and
        // the user's own 34 MB of fingerprints is not this test's to overwrite.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scolo-regroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = PhotoDuplicateService(
            library: library, visionRevision: 2, cacheDirectory: directory
        )
        return (service, library, directory)
    }

    @Test("A regroup changes the grouping without asking the library for anything")
    func regroupNeedsNoLibrary() async throws {
        let (service, library, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        let swept = try await service.sweep(similarity: .standard)
        #expect(swept.groups.count == 1, "0.3 apart is inside 0.35")
        let fetchesAfterSweep = library.fetchCount
        let printsAfterSweep = library.fingerprintCount
        #expect(fetchesAfterSweep == 1)
        #expect(printsAfterSweep == 2)

        let tightened = try await service.regroup(similarity: .strict)
        #expect(tightened?.groups.isEmpty == true, "0.3 apart is outside 0.25")
        // The whole point: no second fetch, no second round of fingerprinting, and
        // so no second trip to iCloud for anything without a local thumbnail.
        #expect(library.fetchCount == fetchesAfterSweep)
        #expect(library.fingerprintCount == printsAfterSweep)

        let loosened = try await service.regroup(similarity: .standard)
        #expect(loosened?.groups.count == 1, "and back again, still without the library")
        #expect(library.fetchCount == fetchesAfterSweep)
        #expect(library.fingerprintCount == printsAfterSweep)
    }

    /// Nil is the caller's cue to sweep. Anything else — empty results, say — would
    /// be indistinguishable from a library with no duplicates in it, and the page
    /// would report "no duplicates found" for a library it has never looked at.
    @Test("Regrouping before any sweep reports that there is nothing to regroup")
    func regroupBeforeSweepIsNil() async throws {
        let (service, library, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await service.regroup(similarity: .strict) == nil)
        #expect(library.fetchCount == 0)
    }

    /// A regroup reads no thumbnails, so it can neither add to the skipped count nor
    /// cure it. Recomputing it from the retained prints has to reach the same number
    /// the sweep reported, or the page's "N had no thumbnail" changes for a reason
    /// that has nothing to do with thumbnails.
    @Test("The skipped count survives a regroup unchanged")
    func skippedCountIsStable() async throws {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000),
                      asset("unreadable", seconds: 180, width: 2000)]
        let library = FakeLibrary(assets: assets, prints: [
            "a": PhotoFingerprint(vector: [0, 0, 0]),
            "b": PhotoFingerprint(vector: [0.3, 0, 0])
        ])
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scolo-regroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = PhotoDuplicateService(
            library: library, visionRevision: 2, cacheDirectory: directory
        )

        let swept = try await service.sweep(similarity: .standard)
        #expect(swept.skippedCount == 1)
        let regrouped = try await service.regroup(similarity: .veryLoose)
        #expect(regrouped?.skippedCount == swept.skippedCount)
        #expect(regrouped?.examinedCount == swept.examinedCount)
    }
}
