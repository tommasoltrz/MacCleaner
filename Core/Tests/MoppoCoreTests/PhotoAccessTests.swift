import Foundation
import Testing
@testable import MoppoCore

@Suite("Photos permission before scanning")
struct PhotoAccessTests {
    private actor Library: PhotoLibraryProviding {
        private var access: PhotoLibraryAccess
        private var authorizations = 0
        private var reads = 0
        private var fingerprints = 0
        private var deletions = 0

        init(access: PhotoLibraryAccess) { self.access = access }

        func setAccess(_ access: PhotoLibraryAccess) { self.access = access }
        func authorize() async -> PhotoLibraryAccess {
            authorizations += 1
            return access
        }
        func fetchAssets() async throws -> [PhotoAsset] {
            reads += 1
            return []
        }
        func fingerprint(assetID: String) async -> PhotoFingerprint? {
            fingerprints += 1
            return nil
        }
        func delete(assetIDs: [String]) async throws { deletions += 1 }

        func calls() -> [Int] { [authorizations, reads, fingerprints, deletions] }
    }

    @Test("Requesting access does not read, compare, or delete photos", arguments: [
        PhotoLibraryAccess.authorized, .limited, .denied, .restricted
    ])
    func requestOnly(access: PhotoLibraryAccess) async {
        let library = Library(access: access)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: cache)

        let result = await service.requestAccess()

        #expect(result == access)
        #expect(await library.calls() == [1, 0, 0, 0])
        #expect(await service.isSweeping == false)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Returning to the view reads the current permission decision")
    func permissionChanges() async {
        let library = Library(access: .denied)
        let service = PhotoDuplicateService(library: library, visionRevision: 2)

        #expect(await service.requestAccess() == .denied)
        await library.setAccess(.authorized)
        #expect(await service.requestAccess() == .authorized)
        await library.setAccess(.restricted)
        #expect(await service.requestAccess() == .restricted)
        #expect(await library.calls() == [3, 0, 0, 0])
    }

    @Test("Only a later scan reads assets after access is granted")
    func scanStartsSeparately() async throws {
        let library = Library(access: .authorized)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: cache)

        #expect(await service.requestAccess() == .authorized)
        #expect(await library.calls() == [1, 0, 0, 0])
        _ = try await service.sweep()
        #expect(await library.calls() == [2, 1, 0, 0])
    }
}
