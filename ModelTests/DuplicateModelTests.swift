import Foundation
import Testing
@testable import ScoloCore

@Suite("Duplicate models")
@MainActor
struct DuplicateModelTests {
    @Test("Minimum size filters immediately and removes hidden selections")
    func minimumSizeFiltersWithoutScan() async throws {
        let storage = try ModelTestStorage()
        func group(_ name: String, bytes: Int64) -> FileDuplicateGroup {
            let files = ["keeper", "copy"].map {
                DuplicateFile(url: storage.url.appendingPathComponent(name + $0), logicalBytes: bytes, allocatedBytes: bytes)
            }
            return .init(id: name, keeper: files[0], removable: [files[1]], contentDigest: name)
        }
        let small = group("small", bytes: 100)
        let large = group("large", bytes: 2_000_000)
        let scanner = FixtureFileScanner(.init(groups: [small, large], roots: [storage.url]))
        let model = FileDuplicatesModel(operations: OperationState(), scanner: scanner)
        model.fileDuplicateMinimumBytes = 0
        model.startFileDuplicateScan(roots: [storage.url])
        try await waitForModel { !model.isScanningDuplicateFiles }
        model.selectAllFileDuplicates()
        #expect(model.fileDuplicateSelection.count == 2)
        model.fileDuplicateMinimumBytes = 1_000_000
        #expect(model.fileDuplicateGroups.map(\.id) == [large.id])
        #expect(model.fileDuplicateSelection == [large.removable[0].id])
        model.fileDuplicateMinimumBytes = 0
        #expect(model.fileDuplicateGroups.count == 2)
        #expect(!model.fileDuplicateSelection.contains(small.removable[0].id))
        #expect(await scanner.scans == 1)

        model.toggleFileDuplicate(large.keeper.id)
        #expect(!model.fileDuplicateSelection.contains(large.keeper.id))
        model.keepFileInstead(groupID: large.id, fileID: large.removable[0].id)
        #expect(model.fileDuplicateSelection.contains(large.keeper.id))
        #expect(!model.fileDuplicateSelection.contains(large.removable[0].id))
    }

    @Test("Photo keeper changes preserve card order and deletion completion order")
    func photoSelectionAndCompletion() async throws {
        let storage = try ModelTestStorage()
        let library = FixturePhotoLibrary()
        let service = PhotoDuplicateService(library: library, visionRevision: 1, cacheDirectory: storage.url)
        let model = PhotoDuplicatesModel(service: service, defaults: storage.defaults)
        model.startScan()
        try await waitForModel { !model.isScanning }
        let group = try #require(model.groups.first)
        let promoted = try #require(group.removable.first)
        let originalOrder = group.assets.map(\.id)
        model.keepInstead(groupID: group.id, assetID: promoted.id)
        #expect(model.groups.first?.keeper.id == promoted.id)
        #expect(model.groups.first?.assets.map(\.id) == originalOrder)
        #expect(!model.selection.contains(promoted.id))
        model.setSelected(true, assetID: promoted.id)
        #expect(!model.selection.contains(promoted.id))
        model.selectAll()
        let selected = model.selection
        var completionCount: Int?
        await model.deleteSelected { count in
            #expect(model.isDeleting)
            #expect(model.selection.isEmpty)
            completionCount = count
        }
        #expect(completionCount == selected.count)
        #expect(Set(await library.deletedIDs) == selected)
        #expect(!model.isDeleting)
        #expect(model.groups.isEmpty)
    }

    @Test("Regroup cancellation cannot clear a new scan")
    func regroupThenScan() async throws {
        let storage = try ModelTestStorage()
        let service = PhotoDuplicateService(library: FixturePhotoLibrary(), visionRevision: 1, cacheDirectory: storage.url)
        let model = PhotoDuplicatesModel(service: service, defaults: storage.defaults)
        model.startScan()
        try await waitForModel { !model.isScanning }
        for value in PhotoSimilarity.allCases { model.similarity = value }
        model.startScan()
        #expect(model.isScanning)
        #expect(!model.isRegrouping)
        try await waitForModel { !model.isScanning }
        #expect(!model.isRegrouping)
        #expect(model.groups.count == 1)
    }
}
