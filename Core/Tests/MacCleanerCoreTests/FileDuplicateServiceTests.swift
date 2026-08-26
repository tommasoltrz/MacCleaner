import Foundation
import Testing
@testable import MacCleanerCore

@Suite("File duplicate service")
struct FileDuplicateServiceTests {
    private final class Sandbox {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MacCleanerFileDuplicates-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url
        }
    }

    @Test("Exact copies form one verified group")
    func exactCopies() async throws {
        let box = try Sandbox()
        let data = Data("the same file contents".utf8)
        let first = try box.write("one.txt", data: data)
        let second = try box.write("nested/two.txt", data: data)
        _ = try box.write("same-size-different.txt", data: Data("different file contents".utf8))

        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0, sampleBytes: 4)
        )

        #expect(results.groups.count == 1)
        #expect(Set(results.groups[0].files.map(\.url)) == Set([first, second]))
        #expect(results.removableCount == 1)
    }

    @Test("A sample collision does not become a duplicate")
    func sampleCollision() async throws {
        let box = try Sandbox()
        var first = Data(repeating: 7, count: 100)
        var second = first
        first[20] = 1
        second[20] = 2
        _ = try box.write("one.bin", data: first)
        _ = try box.write("two.bin", data: second)

        let results = try await FileDuplicateService().scan(
            roots: [box.root],
            options: .init(minimumLogicalBytes: 0, sampleBytes: 4, readChunkBytes: 16)
        )

        #expect(results.groups.isEmpty)
    }

    @Test("Hard links do not form a duplicate group")
    func hardLinks() async throws {
        let box = try Sandbox()
        let original = try box.write("original.bin", data: Data(repeating: 4, count: 128))
        try FileManager.default.linkItem(
            at: original, to: box.root.appendingPathComponent("hard-link.bin")
        )

        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )

        #expect(results.groups.isEmpty)
        #expect(results.eligibleCount == 1)
    }

    @Test("A nested root is scanned once")
    func nestedRoots() async throws {
        let box = try Sandbox()
        let nested = box.root.appendingPathComponent("nested")
        let data = Data(repeating: 9, count: 128)
        _ = try box.write("nested/one.bin", data: data)
        _ = try box.write("nested/two.bin", data: data)

        let results = try await FileDuplicateService().scan(
            roots: [nested, box.root], options: .init(minimumLogicalBytes: 0)
        )

        #expect(results.roots == [box.root])
        #expect(results.groups.count == 1)
        #expect(results.examinedCount == 2)
    }

    @Test("Exclusions and the minimum size remove candidates")
    func exclusionsAndMinimumSize() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 3, count: 64)
        _ = try box.write("keep/one.bin", data: data)
        _ = try box.write("skip/two.bin", data: data)
        _ = try box.write("keep/three.tmp", data: data)

        let results = try await FileDuplicateService().scan(
            roots: [box.root],
            options: .init(minimumLogicalBytes: 32),
            excludedPaths: [box.root.appendingPathComponent("skip").path],
            excludedPatterns: ["*.tmp"]
        )

        #expect(results.groups.isEmpty)
        #expect(results.eligibleCount == 1)
    }

    @Test("Promoting a copy preserves one keeper")
    func promotesKeeper() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 5, count: 128)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let group = try #require(results.groups.first)
        let nextKeeper = try #require(group.removable.first)

        let promoted = try #require(group.promoting(nextKeeper.id))

        #expect(promoted.keeper.id == nextKeeper.id)
        #expect(promoted.removable.count == 1)
        #expect(promoted.removable[0].id == group.keeper.id)
        #expect(promoted.keeperReason == .chosenByUser)
    }

    @Test("Removal refuses a group when its keeper changes")
    func refusesChangedKeeper() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 6, count: 128)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let group = try #require(results.groups.first)
        let selected = try #require(group.removable.first)
        try Data("changed".utf8).write(to: group.keeper.url)

        let result = try await FileDuplicateRemovalService().remove(
            selectedIDs: [selected.id], from: [group]
        )

        #expect(FileManager.default.fileExists(atPath: selected.url.path))
        #expect(result.cleanup.failed == [selected.url.path])
        #expect(result.cleanup.removedCount == 0)
        #expect(result.staleFileIDs == [selected.id])
        #expect(result.staleGroupIDs == [group.id])
    }

    @Test("Removal rechecks contents when file metadata matches")
    func refusesChangedContents() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 8, count: 128)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let group = try #require(results.groups.first)
        let selected = try #require(group.removable.first)
        let modificationDate = try #require(selected.modificationDate)
        try Data(repeating: 9, count: 128).write(to: selected.url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate], ofItemAtPath: selected.url.path
        )

        let result = try await FileDuplicateRemovalService().remove(
            selectedIDs: [selected.id], from: [group]
        )

        #expect(FileManager.default.fileExists(atPath: selected.url.path))
        #expect(result.cleanup.failed == [selected.url.path])
        #expect(result.cleanup.removedCount == 0)
        #expect(result.staleFileIDs == [selected.id])
    }

    @Test("Cancellation stops file verification")
    func cancellation() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 2, count: 8 * 1024 * 1024)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        let service = FileDuplicateService()
        let gate = DispatchSemaphore(value: 0)
        let stage = AsyncStream<Void>.makeStream()
        let task = Task {
            try await service.scan(
                roots: [box.root],
                options: .init(
                    minimumLogicalBytes: 0,
                    sampleBytes: 64 * 1024,
                    readChunkBytes: 64 * 1024
                ),
                onProgress: { progress in
                    if progress.stage == .verifying, progress.completed == 0 {
                        stage.continuation.yield()
                        gate.wait()
                    }
                }
            )
        }

        _ = await stage.stream.first { _ in true }
        task.cancel()
        gate.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A verified copy moves to the Trash")
    func removesVerifiedCopy() async throws {
        let box = try Sandbox()
        let suffix = UUID().uuidString
        let data = Data(repeating: 1, count: 128)
        _ = try box.write("maccleaner-duplicate-a-\(suffix).bin", data: data)
        _ = try box.write("maccleaner-duplicate-b-\(suffix).bin", data: data)
        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let group = try #require(results.groups.first)
        let selected = try #require(group.removable.first)
        let trashed = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(selected.url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: trashed) }

        let result = try await FileDuplicateRemovalService().remove(
            selectedIDs: [selected.id], from: [group], keepReceipt: false
        )

        #expect(result.cleanup.removedCount == 1)
        #expect(result.cleanup.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: group.keeper.url.path))
        #expect(!FileManager.default.fileExists(atPath: selected.url.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }
}
