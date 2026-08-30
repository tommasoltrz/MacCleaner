import Foundation
import Testing
@testable import ScoloCore

/// Real APFS clones, made with `clonefile(2)` — the same call Finder makes when it
/// copies within one volume. Nothing here is simulated: if the temporary directory
/// is not on a filesystem that clones, the suite says so and stops rather than
/// asserting against a fake.
@Suite("PrivateSizeMeasurer")
struct PrivateSizeMeasurerTests {

    // MARK: - Fixture helpers

    final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("scolo-clone-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Incompressible bytes: a run of zeros can be stored as a hole, and a file with
    /// no blocks has nothing to share.
    @discardableResult
    private func write(_ name: String, bytes: Int, in sandbox: Sandbox) throws -> URL {
        let url = sandbox.root.appendingPathComponent(name)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }
        try data.write(to: url)
        return url
    }

    /// `clonefile` shares every block, exactly as a Finder copy does.
    private func clone(_ source: URL, to name: String, in sandbox: Sandbox) throws -> URL? {
        let destination = sandbox.root.appendingPathComponent(name)
        guard clonefile(source.path, destination.path, 0) == 0 else { return nil }
        return destination
    }

    /// A plain byte-for-byte copy, sharing nothing.
    @discardableResult
    private func copy(_ source: URL, to name: String, in sandbox: Sandbox) throws -> URL {
        let destination = sandbox.root.appendingPathComponent(name)
        try Data(contentsOf: source).write(to: destination)
        return destination
    }

    // MARK: - The attribute itself

    @Test("a file with no clones reports every one of its bytes as private")
    func lonelyFileOwnsItself() async throws {
        let sandbox = try Sandbox()
        let file = try write("alone.bin", bytes: 512 * 1024, in: sandbox)

        let measurement = try #require(await PrivateSizeMeasurer().measure([file]))
        #expect(measurement.fileCount == 1)
        #expect(measurement.unreportedCount == 0)
        #expect(measurement.privateBytes == measurement.allocatedBytes)
        #expect(measurement.sharedBytes == 0)
        #expect(measurement.containsSharedGroups == false)
    }

    /// The bug this whole type exists for: a 1.05 GB folder copied from Downloads
    /// into Documents reported 1056.89 MB in both places and freed nothing.
    @Test("removing one of two clones frees nothing, and the measurement says so")
    func cloneFreesNothing() async throws {
        let sandbox = try Sandbox()
        let original = try write("original.bin", bytes: 512 * 1024, in: sandbox)
        guard let cloned = try clone(original, to: "cloned.bin", in: sandbox) else {
            Issue.record("this filesystem does not support clonefile; nothing to test")
            return
        }

        let measurement = try #require(await PrivateSizeMeasurer().measure([cloned]))
        #expect(measurement.fileCount == 1)
        #expect(measurement.allocatedBytes >= 512 * 1024)
        #expect(measurement.privateBytes == 0)
        #expect(measurement.sharedBytes == measurement.allocatedBytes)
        // The original is untouched and still holds every byte.
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("a plain copy beside a clone is told apart from it")
    func plainCopyIsNotAClone() async throws {
        let sandbox = try Sandbox()
        let original = try write("original.bin", bytes: 512 * 1024, in: sandbox)
        guard try clone(original, to: "cloned.bin", in: sandbox) != nil else { return }
        let plain = try copy(original, to: "plain.bin", in: sandbox)

        let measurement = try #require(await PrivateSizeMeasurer().measure([plain]))
        #expect(measurement.privateBytes == measurement.allocatedBytes)
        #expect(measurement.containsSharedGroups == false)
    }

    /// Editing part of a clone breaks the sharing for exactly the blocks written —
    /// 100 MB overwritten in a 400 MB clone cost 98 MB of disk on the machine this
    /// was designed against.
    @Test("a diverged clone owns the blocks it rewrote")
    func divergenceCreatesPrivateBytes() async throws {
        let sandbox = try Sandbox()
        let original = try write("original.bin", bytes: 1024 * 1024, in: sandbox)
        guard let cloned = try clone(original, to: "cloned.bin", in: sandbox) else { return }

        let handle = try FileHandle(forWritingTo: cloned)
        var fresh = Data(count: 256 * 1024)
        fresh.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }
        try handle.write(contentsOf: fresh)
        try handle.close()

        let measurement = try #require(await PrivateSizeMeasurer().measure([cloned]))
        #expect(measurement.privateBytes > 0)
        #expect(measurement.privateBytes < measurement.allocatedBytes)
    }

    // MARK: - Set semantics

    @Test("both members of one clone family are flagged, because the sum understates")
    func wholeFamilyInTheSetIsFlagged() async throws {
        let sandbox = try Sandbox()
        let original = try write("original.bin", bytes: 512 * 1024, in: sandbox)
        guard let cloned = try clone(original, to: "cloned.bin", in: sandbox) else { return }

        let measurement = try #require(
            await PrivateSizeMeasurer().measure([original, cloned])
        )
        #expect(measurement.fileCount == 2)
        // Neither owns the shared blocks, so the honest sum is zero — and removing
        // both would in fact free them. The flag is what lets the interface say
        // "at least" instead of quoting a total it knows is low.
        #expect(measurement.privateBytes == 0)
        #expect(measurement.containsSharedGroups)
    }

    @Test("two unrelated files are not mistaken for a family")
    func distinctFilesAreNotAFamily() async throws {
        let sandbox = try Sandbox()
        let first = try write("first.bin", bytes: 256 * 1024, in: sandbox)
        let second = try write("second.bin", bytes: 256 * 1024, in: sandbox)

        let measurement = try #require(await PrivateSizeMeasurer().measure([first, second]))
        #expect(measurement.fileCount == 2)
        #expect(measurement.containsSharedGroups == false)
        #expect(measurement.privateBytes == measurement.allocatedBytes)
    }

    // MARK: - The rules it shares with AllocatedSizeMeasurer

    @Test("a hard-linked inode is counted once")
    func hardLinksCountOnce() async throws {
        let sandbox = try Sandbox()
        let file = try write("linked.bin", bytes: 512 * 1024, in: sandbox)
        let link = sandbox.root.appendingPathComponent("second-name.bin")
        try FileManager.default.linkItem(at: file, to: link)

        let alone = try #require(await PrivateSizeMeasurer().measure([file]))
        let both = try #require(await PrivateSizeMeasurer().measure([file, link]))
        // Two names, one inode, one set of blocks: the second name adds nothing.
        #expect(both.privateBytes == alone.privateBytes)
        #expect(both.fileCount == 1)
    }

    @Test("a symlink is not followed, so its target's bytes stay out")
    func symlinksAreNotFollowed() async throws {
        let sandbox = try Sandbox()
        let file = try write("target.bin", bytes: 512 * 1024, in: sandbox)
        let link = sandbox.root.appendingPathComponent("pointer")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let measurement = try #require(await PrivateSizeMeasurer().measure([link]))
        #expect(measurement.fileCount == 0)
        #expect(measurement.privateBytes == 0)
    }

    @Test("a directory is summed from the files under it, packages included")
    func directoriesAreWalked() async throws {
        let sandbox = try Sandbox()
        let folder = sandbox.root.appendingPathComponent("Folder.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            var data = Data(count: 128 * 1024)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                arc4random_buf(base, raw.count)
            }
            try data.write(to: folder.appendingPathComponent("part\(index).bin"))
        }

        let measurement = try #require(
            await PrivateSizeMeasurer().measure([sandbox.root.appendingPathComponent("Folder.app")])
        )
        #expect(measurement.fileCount == 3)
        #expect(measurement.privateBytes >= 3 * 128 * 1024)
    }

    @Test("nothing to measure is zero, which is an answer, not an absence")
    func emptyInputMeasuresToZero() async throws {
        let measurement = try #require(await PrivateSizeMeasurer().measure([]))
        #expect(measurement == .zero)
    }

    @Test("a path that does not exist reports nothing rather than zero bytes")
    func unreadablePathsAreNotCountedAsEmpty() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        // Every file asked refused to answer, so the measurer declines to claim a
        // total. A caller that read `0` here would promise to free nothing.
        let measurement = try await PrivateSizeMeasurer().measure([missing])
        #expect(measurement == nil)
    }
}
