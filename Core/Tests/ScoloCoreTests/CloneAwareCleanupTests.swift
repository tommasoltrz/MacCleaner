import Foundation
import Testing
@testable import ScoloCore

/// Scolo used to promise back every byte a selection occupied. On APFS that is an
/// upper bound, not a promise: a Finder copy within one volume is a clone, and the
/// two copies share their blocks. The case that started this — a 1.05 GB folder
/// copied from `~/Downloads` into `~/Documents` — reported 1056.89 MB in both
/// places, and removing either one would have freed nothing at all.
///
/// Every fixture here is a real clone, made with `clonefile(2)`.
@Suite("Clone-aware cleanup")
struct CloneAwareCleanupTests {

    private let oneMB = 1_048_576

    final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("scolo-clone-cleanup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Incompressible, so the bytes are really on disk and really shareable.
    private func writeFile(_ name: String, bytes: Int, in sandbox: Sandbox) throws -> URL {
        let url = sandbox.root.appendingPathComponent(name)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }
        try data.write(to: url)
        return url
    }

    private func clone(_ source: URL, to name: String, in sandbox: Sandbox) -> URL? {
        let destination = sandbox.root.appendingPathComponent(name)
        guard clonefile(source.path, destination.path, 0) == 0 else { return nil }
        return destination
    }

    private func entry(_ url: URL) -> FileEntry {
        FileEntry(url: url, kind: .file, allocatedBytes: 0)
    }

    /// Trash fixtures land in the real `~/.Trash`; take them back out again.
    private func discardFromRealTrash(named name: String) {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
    }

    // MARK: - The outcome

    @Test("removing one of two clones reports the size it occupied and nothing freed")
    func removingOneCloneFreesNothing() async throws {
        let sandbox = try Sandbox()
        let original = try writeFile("original.bin", bytes: 4 * oneMB, in: sandbox)
        let name = "scolo-clone-\(UUID().uuidString).bin"
        guard let cloned = clone(original, to: name, in: sandbox) else {
            Issue.record("this filesystem does not support clonefile; nothing to test")
            return
        }
        defer { discardFromRealTrash(named: name) }

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        let outcome = try await CleanupService(log: log)
            .remove(entries: [entry(cloned)], trashFirst: true)

        #expect(outcome.removedCount == 1)
        #expect(outcome.unreportedFreedCount == 0)
        // It occupied 4 MB and gave back nothing: the original still holds every
        // block. This is the exact figure the old code promised as reclaimed.
        #expect(outcome.removedBytes >= Int64(4 * oneMB))
        #expect(outcome.freedBytes == 0)
        #expect(outcome.sharedBytes == outcome.removedBytes)
        #expect(FileManager.default.fileExists(atPath: original.path))

        let logged = try #require(log.recentEntries().first)
        #expect(logged.bytes == outcome.removedBytes)
        #expect(logged.freedBytes == 0)
    }

    /// The property the design rests on, and it holds only for a *permanent*
    /// deletion. Private size is read for each item in the instant before that item
    /// goes, so the second of a cloned pair is measured after the first has already
    /// been deleted — by which time it holds those blocks alone and reports all of
    /// them. The sum is then exact, though no single reading could have said so.
    @Test("deleting both clones telescopes to the whole size")
    func deletingBothClonesFreesEverything() async throws {
        let sandbox = try Sandbox()
        let original = try writeFile("a.bin", bytes: 4 * oneMB, in: sandbox)
        guard let cloned = clone(original, to: "b.bin", in: sandbox) else { return }

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        ).remove(entries: [entry(original), entry(cloned)], trashFirst: false)

        #expect(outcome.removedCount == 2)
        #expect(outcome.deletedCount == 2)
        #expect(outcome.unreportedFreedCount == 0)
        // Two files, 4 MB of blocks between them: they occupied 8 MB and the disk
        // gains 4. Neither of the two wrong answers, which are 8 and 0.
        #expect(outcome.removedBytes >= Int64(8 * oneMB))
        #expect(outcome.freedBytes >= Int64(4 * oneMB))
        #expect(outcome.freedBytes < outcome.removedBytes)
    }

    /// Trashing is the case the telescoping does *not* cover, and the reason the
    /// figure is documented as a floor. A trashed file still exists — that is the
    /// whole point of the Trash — so the first clone keeps holding the blocks while
    /// the second is measured, and both read zero. Emptying the Trash later frees
    /// the 4 MB that neither removal could claim.
    @Test("trashing both clones claims nothing, because a trashed file still holds its blocks")
    func trashingBothClonesClaimsNothing() async throws {
        let sandbox = try Sandbox()
        let firstName = "scolo-clone-a-\(UUID().uuidString).bin"
        let secondName = "scolo-clone-b-\(UUID().uuidString).bin"
        let original = try writeFile(firstName, bytes: 4 * oneMB, in: sandbox)
        guard let cloned = clone(original, to: secondName, in: sandbox) else { return }
        defer {
            discardFromRealTrash(named: firstName)
            discardFromRealTrash(named: secondName)
        }

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        ).remove(entries: [entry(original), entry(cloned)], trashFirst: true)

        #expect(outcome.removedCount == 2)
        #expect(outcome.removedBytes >= Int64(8 * oneMB))
        // Understated on purpose. The alternative is claiming space the disk has
        // not given back and may never give back.
        #expect(outcome.freedBytes == 0)
    }

    @Test("a file that shares nothing gives back everything it occupied")
    func ordinaryFileIsUnaffected() async throws {
        let sandbox = try Sandbox()
        let name = "scolo-plain-\(UUID().uuidString).bin"
        let file = try writeFile(name, bytes: 3 * oneMB, in: sandbox)
        defer { discardFromRealTrash(named: name) }

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        ).remove(entries: [entry(file)], trashFirst: true)

        #expect(outcome.freedBytes == outcome.removedBytes)
        #expect(outcome.sharedBytes == 0)
    }

    // MARK: - The receipt

    @Test("the freed figure round-trips through the removal log")
    func freedBytesRoundTrip() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        let stamp = Date(timeIntervalSince1970: 1_756_000_000)
        try log.append([
            RemovalRecord(
                timestamp: stamp, originalPath: "/tmp/clone.bin", bytes: 4_194_304,
                disposition: .trashed, trashedPath: "/tmp/.Trash/clone.bin",
                trashedIdentity: "16777232:12345", freedBytes: 0
            )
        ])
        let read = try #require(log.recentEntries().first)
        #expect(read.bytes == 4_194_304)
        #expect(read.freedBytes == 0)
        #expect(read.trashedPath == "/tmp/.Trash/clone.bin")
        // The identity Put Back depends on must survive the new trailing field.
        #expect(read.trashedIdentity == "16777232:12345")
    }

    /// A permanent deletion has no Trash path, so the freed figure needs a
    /// placeholder to sit behind. It must not come back as a path of its own.
    @Test("a permanent deletion records freed bytes without inventing a Trash path")
    func permanentDeletionCarriesFreedBytes() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        try log.append([
            RemovalRecord(
                timestamp: Date(timeIntervalSince1970: 1_756_000_001),
                originalPath: "/tmp/gone.bin", bytes: 900,
                disposition: .deleted, freedBytes: 700
            )
        ])
        let read = try #require(log.recentEntries().first)
        #expect(read.trashedPath == nil)
        #expect(read.trashedIdentity == nil)
        #expect(read.freedBytes == 700)
    }

    @Test("a line written before this field existed still parses, and claims nothing")
    func legacyLinesStillParse() throws {
        let legacy = RemovalLog.record(
            from: "2026-08-18T09:41:00Z \"/tmp/old.bin\" 2048 trashed \"/tmp/.Trash/old.bin\" 16777232:99"
        )
        let record = try #require(legacy)
        #expect(record.bytes == 2048)
        #expect(record.trashedIdentity == "16777232:99")
        // No figure was recorded, so none is invented.
        #expect(record.freedBytes == nil)
    }

    // MARK: - The history

    @Test("history reports what was freed beside what was removed")
    func historySumsFreedBytes() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        let stamp = Date(timeIntervalSince1970: 1_756_000_002)
        try log.append([
            RemovalRecord(timestamp: stamp, originalPath: "/tmp/a.bin", bytes: 1000,
                          disposition: .trashed, trashedPath: "/tmp/.Trash/a.bin",
                          trashedIdentity: "1:1", freedBytes: 0),
            RemovalRecord(timestamp: stamp, originalPath: "/tmp/b.bin", bytes: 500,
                          disposition: .deleted, freedBytes: 500),
        ])

        let summary = CleanupHistoryService(log: log).summary()
        #expect(summary.removedBytes == 1500)
        #expect(summary.freedBytes == 500)
    }

    /// History written before the freed field existed must read exactly as it did.
    /// Falling back to the occupied size makes the two totals agree, which is the
    /// honest way to say "this was never measured".
    @Test("receipts without a freed figure fall back to what they occupied")
    func legacyHistoryIsUnchanged() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        try log.append([
            RemovalRecord(
                timestamp: Date(timeIntervalSince1970: 1_756_000_003),
                originalPath: "/tmp/legacy.bin", bytes: 4096, disposition: .deleted
            )
        ])
        let summary = CleanupHistoryService(log: log).summary()
        #expect(summary.removedBytes == 4096)
        #expect(summary.freedBytes == 4096)
    }
}
