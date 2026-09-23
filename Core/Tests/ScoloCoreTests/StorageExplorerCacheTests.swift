import Foundation
import Testing
@testable import ScoloCore

@Suite("Storage Explorer cache")
struct StorageExplorerCacheTests {
    private let home = URL(fileURLWithPath: "/cache-fixture/home")

    private func item(_ path: String, bytes: Int64, count: Int = 1) -> StorageExplorerItem {
        StorageExplorerItem(
            url: home.appendingPathComponent(path), kind: .folder,
            allocatedBytes: bytes, fileCount: count, identity: path
        )
    }

    private func snapshot(_ path: String, _ items: [StorageExplorerItem]) -> StorageExplorerSnapshot {
        StorageExplorerSnapshot(
            directory: home.appendingPathComponent(path), items: items,
            allocatedBytes: items.reduce(0) { $0 + $1.allocatedBytes },
            fileCount: items.reduce(0) { $0 + $1.fileCount }, unreadableCount: 0
        )
    }

    private func move(_ item: StorageExplorerItem, to path: String) -> RemovalRecord {
        RemovalRecord(
            timestamp: Date(), originalPath: item.url.path, bytes: item.allocatedBytes,
            disposition: .trashed, trashedPath: home.appendingPathComponent(path).path,
            trashedIdentity: item.identity
        )
    }

    @Test("nested removals update parents and Trash without reducing their shared total")
    func nestedMove() throws {
        let removed = item("Documents/Project/build", bytes: 30, count: 3)
        let kept = item("Documents/Project/source", bytes: 70, count: 7)
        var cache = StorageExplorerCache()
        cache.store(snapshot("", [item("Documents", bytes: 100, count: 10), item(".Trash", bytes: 20, count: 2)]))
        cache.store(snapshot("Documents", [item("Documents/Project", bytes: 100, count: 10)]))
        cache.store(snapshot("Documents/Project", [removed, kept]))
        cache.store(snapshot("Documents/Project/build", [item("Documents/Project/build/output", bytes: 30)]))
        cache.store(snapshot(".Trash", [item(".Trash/old", bytes: 20, count: 2)]))
        cache.store(snapshot("Other", [item("Other/file", bytes: 50)]))

        cache.applyRemovals([move(removed, to: ".Trash/build 2")], items: [removed])

        let parentSnapshot = cache.snapshot(for: home.appendingPathComponent("Documents"))
        let parent = try #require(parentSnapshot)
        #expect(parent.allocatedBytes == 70)
        #expect(parent.fileCount == 7)
        #expect(parent.isEstimated)
        let currentSnapshot = cache.snapshot(for: home.appendingPathComponent("Documents/Project"))
        let current = try #require(currentSnapshot)
        #expect(current.items == [kept])
        #expect(cache.snapshot(for: removed.url) == nil)
        let rootSnapshot = cache.snapshot(for: home)
        let root = try #require(rootSnapshot)
        #expect(root.allocatedBytes == 120)
        #expect(root.fileCount == 12)
        #expect(root.items.map(\.allocatedBytes) == [70, 50])
        let trashSnapshot = cache.snapshot(for: home.appendingPathComponent(".Trash"))
        let trash = try #require(trashSnapshot)
        #expect(trash.allocatedBytes == 50)
        #expect(trash.items.last?.name == "build 2")
        #expect(trash.items.last?.protectionReason == .trash)
        #expect(cache.snapshot(for: home.appendingPathComponent("Other"))?.isEstimated == false)
    }

    @Test("partial failure changes only confirmed items and supports repeated moves")
    func partialRemoval() throws {
        let first = item("Project/first", bytes: 30)
        let second = item("Project/second", bytes: 20)
        var cache = StorageExplorerCache()
        cache.store(snapshot("Project", [first, second]))
        let failed = RemovalRecord(timestamp: Date(), originalPath: second.url.path, bytes: 20, disposition: .failed)
        cache.applyRemovals([move(first, to: ".Trash/first"), failed], items: [first, second])
        #expect(cache.snapshot(for: first.url.deletingLastPathComponent())?.items == [second])
        cache.applyRemovals([move(second, to: ".Trash/second")], items: [second])
        #expect(cache.snapshot(for: first.url.deletingLastPathComponent())?.items.isEmpty == true)
        #expect(cache.snapshot(for: first.url.deletingLastPathComponent())?.allocatedBytes == 0)
    }

    @Test("a move between volumes does not add bytes to the source volume")
    func externalTrash() throws {
        let removed = item("Documents/build", bytes: 30)
        var cache = StorageExplorerCache()
        cache.store(snapshot("", [item("Documents", bytes: 100)]))
        var record = move(removed, to: ".Trash/build")
        record.trashedPath = "/cache-fixture/other-volume/.Trashes/501/build"
        cache.applyRemovals([record], items: [removed])
        #expect(cache.snapshot(for: home)?.allocatedBytes == 70)
    }

    @Test("a newly created Trash folder keeps the shared parent total")
    func newTrashFolder() {
        let removed = item("Documents/build", bytes: 30)
        var cache = StorageExplorerCache()
        cache.store(snapshot("", [item("Documents", bytes: 100)]))
        cache.applyRemovals([move(removed, to: ".Trash/build")], items: [removed])
        let updated = cache.snapshot(for: home)
        #expect(updated?.allocatedBytes == 100)
        #expect(updated?.items.last?.url.lastPathComponent == ".Trash")
        #expect(updated?.items.last?.protectionReason == .trash)
    }

    @Test("alternate paths match Trash by directory identity")
    func alternatePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("Actual")
        let alias = root.appendingPathComponent("Alias")
        for name in ["Documents", ".Trash"] {
            try FileManager.default.createDirectory(at: actual.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let items = ["Documents", ".Trash"].map { name in
            StorageExplorerItem(
                url: alias.appendingPathComponent(name), kind: .folder,
                allocatedBytes: name == "Documents" ? 100 : 20,
                identity: FileIdentity.of(alias.appendingPathComponent(name))
            )
        }
        let removed = StorageExplorerItem(url: alias.appendingPathComponent("Documents/file"), kind: .file, allocatedBytes: 30)
        let record = RemovalRecord(
            timestamp: Date(), originalPath: removed.url.path, bytes: 30, disposition: .trashed,
            trashedPath: actual.appendingPathComponent(".Trash/file").path
        )
        var cache = StorageExplorerCache()
        cache.store(StorageExplorerSnapshot(directory: alias, items: items, allocatedBytes: 120, fileCount: 0, unreadableCount: 0))
        cache.applyRemovals([record], items: [removed])
        let updated = cache.snapshot(for: alias)
        #expect(updated?.allocatedBytes == 120)
        #expect(updated?.items.map(\.allocatedBytes) == [70, 50])
    }

    @Test("fresh measurements replace estimates and the cache remains bounded")
    func freshAndBounded() {
        var cache = StorageExplorerCache(limit: 2)
        cache.store(snapshot("One", []))
        cache.store(snapshot("Two", []))
        cache.invalidate()
        #expect(cache.snapshot(for: home.appendingPathComponent("One"))?.isEstimated == true)
        cache.store(snapshot("One", []))
        #expect(cache.snapshot(for: home.appendingPathComponent("One"))?.isEstimated == false)
        cache.store(snapshot("Three", []))
        #expect(cache.snapshot(for: home.appendingPathComponent("Two")) == nil)
    }

    @Test("a manual measurement invalidates related folders without changing unrelated folders")
    func relatedMeasurements() {
        var cache = StorageExplorerCache()
        for path in ["", "Project", "Project/Build", "Project-copy"] {
            cache.store(snapshot(path, []))
        }
        cache.invalidate(relatedTo: home.appendingPathComponent("Project"))
        #expect(cache.snapshot(for: home)?.isEstimated == true)
        #expect(cache.snapshot(for: home.appendingPathComponent("Project"))?.isEstimated == true)
        #expect(cache.snapshot(for: home.appendingPathComponent("Project/Build"))?.isEstimated == true)
        #expect(cache.snapshot(for: home.appendingPathComponent("Project-copy"))?.isEstimated == false)
    }

    @Test("the row budget evicts older folders but permits one large folder")
    func rowBudget() {
        var cache = StorageExplorerCache()
        let rows = (0..<25_001).map { item("Wide/\($0)", bytes: 1) }
        cache.store(snapshot("One", rows))
        cache.store(snapshot("Two", rows))
        #expect(cache.snapshot(for: home.appendingPathComponent("One")) == nil)
        #expect(cache.snapshot(for: home.appendingPathComponent("Two")) != nil)
        cache.store(snapshot("Large", rows + rows))
        #expect(cache.snapshot(for: home.appendingPathComponent("Two")) == nil)
        #expect(cache.snapshot(for: home.appendingPathComponent("Large"))?.items.count == 50_002)
    }
}
