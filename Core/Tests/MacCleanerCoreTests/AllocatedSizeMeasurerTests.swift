import Foundation
import Testing
@testable import MacCleanerCore

/// These tests exist because the Electron predecessor got every one of them wrong.
/// Each case names the real bug it guards.
@Suite("AllocatedSizeMeasurer")
struct AllocatedSizeMeasurerTests {

    // MARK: - Fixture helpers

    /// A temporary directory removed when the test finishes.
    final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("maccleaner-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit {
            // Restore permissions first, or an 0o000 fixture cannot be cleaned up.
            if let walker = FileManager.default.enumerator(atPath: root.path) {
                for case let relative as String in walker {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: root.appendingPathComponent(relative).path
                    )
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func writeFile(_ relativePath: String, bytes: Int) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        func directory(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private static let oneMB = 1024 * 1024

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var activeCallbacks = 0
        private var recordedSnapshots: [SizeMeasurement] = []
        private var foundConcurrentCallback = false

        func record(_ measurement: SizeMeasurement) {
            lock.lock()
            activeCallbacks += 1
            foundConcurrentCallback = foundConcurrentCallback || activeCallbacks > 1
            recordedSnapshots.append(measurement)
            lock.unlock()

            // Keep the callback active long enough to expose concurrent delivery.
            Thread.sleep(forTimeInterval: 0.002)

            lock.lock()
            activeCallbacks -= 1
            lock.unlock()
        }

        var result: (snapshots: [SizeMeasurement], foundConcurrency: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (recordedSnapshots, foundConcurrentCallback)
        }
    }

    @discardableResult
    private static func runHdiutil(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - The regression that motivated the rewrite

    @Test("an unreadable subdirectory costs only itself — it never zeroes the total")
    func unreadableSubdirectoryDoesNotZeroTheTotal() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("readable/a.bin", bytes: Self.oneMB)
        try sandbox.writeFile("readable/b.bin", bytes: Self.oneMB)
        let locked = try sandbox.directory("locked")
        try sandbox.writeFile("locked/secret.bin", bytes: Self.oneMB)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let result = try await AllocatedSizeMeasurer().measure(sandbox.root)

        // `du` would have exited non-zero here and the old code returned 0.
        #expect(result.allocatedBytes >= Int64(2 * Self.oneMB))
        #expect(result.fileCount == 2)
        // The gap is reported, not hidden.
        #expect(result.unreadableCount > 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    @Test("a fully readable tree reports no unreadable entries")
    func cleanTreeHasNoGaps() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("one.bin", bytes: Self.oneMB)
        try sandbox.writeFile("nested/two.bin", bytes: Self.oneMB)

        let result = try await AllocatedSizeMeasurer().measure(sandbox.root)

        #expect(result.fileCount == 2)
        #expect(result.unreadableCount == 0)
        #expect(result.allocatedBytes >= Int64(2 * Self.oneMB))
    }

    // MARK: - Counting rules

    @Test("hard links to one inode are counted once")
    func hardLinksCountedOnce() async throws {
        let sandbox = try Sandbox()
        let original = try sandbox.writeFile("original.bin", bytes: 4 * Self.oneMB)
        let link = sandbox.root.appendingPathComponent("hardlink.bin")
        try FileManager.default.linkItem(at: original, to: link)

        let result = try await AllocatedSizeMeasurer().measure(sandbox.root)

        #expect(result.fileCount == 1, "both directory entries point at one inode")
        #expect(result.allocatedBytes < Int64(8 * Self.oneMB), "must not double-count")
    }

    @Test("symlinks are not followed by default")
    func symlinksIgnoredByDefault() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("real/payload.bin", bytes: 2 * Self.oneMB)
        let outside = try sandbox.writeFile("outside/elsewhere.bin", bytes: 8 * Self.oneMB)
        try FileManager.default.createSymbolicLink(
            at: sandbox.root.appendingPathComponent("real/link.bin"),
            withDestinationURL: outside
        )

        let measured = try await AllocatedSizeMeasurer()
            .measure(sandbox.root.appendingPathComponent("real"))

        #expect(measured.fileCount == 1)
        #expect(measured.allocatedBytes < Int64(8 * Self.oneMB))
    }

    /// Documents a real limitation rather than asserting a capability we do not have.
    ///
    /// APFS clones share blocks, but no per-file API exposes that sharing, so both
    /// clones report their full allocated size. A reported total is therefore an
    /// upper bound on reclaimable space. This test pins the behaviour so nobody
    /// "fixes" it into a false promise, and so the UI copy stays honest.
    @Test("APFS clones are counted per file — totals are an upper bound")
    func clonesAreCountedPerFile() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.writeFile("source.bin", bytes: 16 * Self.oneMB)
        let clone = sandbox.root.appendingPathComponent("clone.bin")

        // `cp -c` requests a clonefile; skip if the filesystem cannot provide one.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", source.path, clone.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "clonefile unavailable on this volume")

        let result = try await AllocatedSizeMeasurer().measure(sandbox.root)

        #expect(result.fileCount == 2, "clones are two distinct inodes, unlike hard links")
        // Both report full size: block sharing between distinct files is invisible
        // to totalFileAllocatedSize. Deleting both would reclaim roughly half this.
        #expect(result.allocatedBytes >= Int64(32 * Self.oneMB))
    }

    // MARK: - Behaviour

    @Test("measureChildren splits a tree without exceeding the whole")
    func childrenSumToParent() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("alpha/a.bin", bytes: 3 * Self.oneMB)
        try sandbox.writeFile("beta/b.bin", bytes: 5 * Self.oneMB)

        let measurer = AllocatedSizeMeasurer()
        let children = try await measurer.measureChildren(of: sandbox.root)
        let whole = try await measurer.measure(sandbox.root)

        #expect(children.count == 2)
        let childTotal = children.values.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(childTotal == whole.allocatedBytes)
    }

    @Test("measureChildren measures a mounted child from that child's volume")
    func mountedChildUsesItsOwnVolumeBoundary() async throws {
        let sandbox = try Sandbox()
        let image = sandbox.root.deletingLastPathComponent()
            .appendingPathComponent("maccleaner-volume-\(UUID().uuidString).dmg")
        let mount = try sandbox.directory("mounted-volume")

        defer {
            _ = try? Self.runHdiutil(["detach", "-quiet", mount.path])
            try? FileManager.default.removeItem(at: image)
        }

        let created = try Self.runHdiutil([
            "create", "-quiet", "-size", "32m", "-fs", "APFS",
            "-volname", "MacCleanerMeasureTest", image.path
        ])
        try #require(created == 0, "could not create the mounted-volume fixture")

        let attached = try Self.runHdiutil([
            "attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path
        ])
        try #require(attached == 0, "could not attach the mounted-volume fixture")

        let payload = mount.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: Self.oneMB).write(to: payload)

        let children = try await AllocatedSizeMeasurer().measureChildren(of: sandbox.root)
        // `/var` is a symlink to `/private/var`. `contentsOfDirectory` can return
        // either spelling, so identify this unique fixture by its final component.
        let mountedChild = try #require(children.first {
            $0.key.lastPathComponent == mount.lastPathComponent
        }?.value)

        #expect(mountedChild.fileCount == 1)
        #expect(mountedChild.allocatedBytes >= Int64(Self.oneMB))
    }

    @Test("progress callbacks are serial, ordered, and not duplicated")
    func progressCallbacksAreSerialAndOrdered() async throws {
        let sandbox = try Sandbox()
        for directory in 0..<4 {
            for file in 0..<520 {
                try sandbox.writeFile("dir-\(directory)/file-\(file)", bytes: 1)
            }
        }
        let recorder = ProgressRecorder()

        let result = try await AllocatedSizeMeasurer().measure(
            sandbox.root,
            progress: { recorder.record($0) }
        )
        let recorded = recorder.result

        #expect(result.fileCount == 2_080)
        #expect(recorded.snapshots.count == 4)
        #expect(!recorded.foundConcurrency)
        for (earlier, later) in zip(recorded.snapshots, recorded.snapshots.dropFirst()) {
            #expect(earlier.fileCount < later.fileCount)
            #expect(earlier.allocatedBytes < later.allocatedBytes)
        }
    }

    @Test("measurements reuse the process-wide worker threads")
    func measurementsReuseWorkers() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("first/file.bin", bytes: 1)
        let measurer = AllocatedSizeMeasurer()

        _ = try await measurer.measure(sandbox.root)
        let firstWorkers = AllocatedSizeMeasurer.sharedWorkerIdentities
        _ = try await measurer.measure(sandbox.root)
        let secondWorkers = AllocatedSizeMeasurer.sharedWorkerIdentities

        #expect(!firstWorkers.isEmpty)
        #expect(firstWorkers.count <= 8)
        #expect(firstWorkers == secondWorkers)
    }

    /// Regression: `.skipsPackageDescendants` was briefly set alongside the symlink
    /// option, which made `/Applications` measure as roughly zero — every .app is a
    /// package, so all their contents were skipped.
    @Test("package contents are measured — an .app bundle is not opaque")
    func descendsIntoPackages() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("Demo.app/Contents/MacOS/Demo", bytes: 6 * Self.oneMB)
        try sandbox.writeFile("Demo.app/Contents/Info.plist", bytes: 1024)

        let result = try await AllocatedSizeMeasurer().measure(sandbox.root)

        #expect(result.fileCount == 2)
        #expect(result.allocatedBytes >= Int64(6 * Self.oneMB))
    }

    @Test("measuring a missing path yields zero rather than throwing")
    func missingPathIsZero() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let result = try await AllocatedSizeMeasurer().measure(missing)
        #expect(result.allocatedBytes == 0)
        #expect(result.fileCount == 0)
    }

    @Test("cancellation is honoured mid-traversal")
    func cancellationHonoured() async throws {
        let sandbox = try Sandbox()
        for index in 0..<2_000 {
            try sandbox.writeFile("bulk/file-\(index).bin", bytes: 1024)
        }

        let task = Task { try await AllocatedSizeMeasurer().measure(sandbox.root) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
