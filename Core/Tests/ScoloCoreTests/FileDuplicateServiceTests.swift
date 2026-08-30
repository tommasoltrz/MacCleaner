import Foundation
import Testing
@testable import ScoloCore

@Suite("File duplicate service")
struct FileDuplicateServiceTests {
    private final class Sandbox {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ScoloFileDuplicates-\(UUID().uuidString)")
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
        _ = try box.write("scolo-duplicate-a-\(suffix).bin", data: data)
        _ = try box.write("scolo-duplicate-b-\(suffix).bin", data: data)
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

    @Test("A second scan is refused while one runs")
    func refusesConcurrentScan() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 2, count: 4 * 1024 * 1024)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        let service = FileDuplicateService()
        let gate = DispatchSemaphore(value: 0)
        let stage = AsyncStream<Void>.makeStream()
        let first = Task {
            try await service.scan(
                roots: [box.root],
                options: .init(minimumLogicalBytes: 0),
                onProgress: { progress in
                    if progress.stage == .verifying, progress.completed == 0 {
                        stage.continuation.yield()
                        gate.wait()
                    }
                }
            )
        }
        _ = await stage.stream.first { _ in true }

        let root = box.root
        await #expect(throws: FileDuplicateError.alreadyRunning) {
            try await service.scan(roots: [root], options: .init(minimumLogicalBytes: 0))
        }

        gate.signal()
        let results = try await first.value
        #expect(results.groups.count == 1)
    }

    @Test("Equal creation dates make the keeper the first by name, and say so")
    func keeperLabelIsHonest() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 5, count: 128)
        let a = try box.write("a.bin", data: data)
        let b = try box.write("b.bin", data: data)
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [a, b] {
            try FileManager.default.setAttributes([.creationDate: sameDate], ofItemAtPath: url.path)
        }

        let tied = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let tiedGroup = try #require(tied.groups.first)
        #expect(tiedGroup.keeperReason == .firstByName)
        #expect(tiedGroup.keeper.url == a)

        // Now `b` is genuinely older: it keeps, and the label may claim it.
        try FileManager.default.setAttributes(
            [.creationDate: sameDate.addingTimeInterval(-3_600)], ofItemAtPath: b.path
        )
        let dated = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let datedGroup = try #require(dated.groups.first)
        #expect(datedGroup.keeperReason == .oldestCopy)
        #expect(datedGroup.keeper.url == b)
    }

    @Test("Progress is throttled, never runs backwards, and ends done")
    func progressIsOrdered() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 3, count: 256)
        for index in 0..<200 {
            _ = try box.write("copy-\(index).bin", data: data)
        }
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [FileDuplicateService.Progress] = []
            func append(_ progress: FileDuplicateService.Progress) {
                lock.lock(); entries.append(progress); lock.unlock()
            }
            var all: [FileDuplicateService.Progress] { lock.lock(); defer { lock.unlock() }; return entries }
        }
        let log = Log()

        _ = try await FileDuplicateService().scan(
            roots: [box.root],
            options: .init(minimumLogicalBytes: 0),
            onProgress: { log.append($0) }
        )

        let entries = log.all
        #expect(entries.last?.stage == .done)
        // Far fewer reports than files: 200 sampled + 200 verified would have
        // been 400 per-file reports before the throttle.
        #expect(entries.count < 60)
        for stage in [FileDuplicateService.Progress.Stage.sampling, .verifying] {
            let steps = entries.filter { $0.stage == stage }.map(\.completed)
            #expect(steps == steps.sorted())
            #expect(steps.first == 0)
            #expect(steps.last == 200)
        }
    }

    @Test("A group whose every copy left disappears; a partial removal keeps it")
    func removingFilesFromGroup() async throws {
        let box = try Sandbox()
        let data = Data(repeating: 4, count: 128)
        _ = try box.write("one.bin", data: data)
        _ = try box.write("two.bin", data: data)
        _ = try box.write("three.bin", data: data)
        let results = try await FileDuplicateService().scan(
            roots: [box.root], options: .init(minimumLogicalBytes: 0)
        )
        let group = try #require(results.groups.first)
        #expect(group.removable.count == 2)

        let partial = try #require(group.removingFiles(withIDs: [group.removable[0].id]))
        #expect(partial.removable.count == 1)
        #expect(partial.keeper == group.keeper)
        #expect(group.removingFiles(withIDs: Set(group.removable.map(\.id))) == nil)
    }
}
