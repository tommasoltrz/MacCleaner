import Foundation
import Testing
@testable import ScoloCore

/// `SystemCachesScanner.scan` against a fixture home, for its third root.
///
/// `~/.cache` came here from Hidden & System Data on 20 Sep 2026. That category
/// shipped switched off, so on a default install nothing under `~/.cache` was offered
/// at all, and where it was offered it was one row: 4.07 GB on this Mac, holding
/// uv's cache, a Codex runtime with its binaries, and Hugging Face models.
@Suite("System Caches: ~/.cache")
struct SystemCachesScanTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-syscache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 2 * 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }

        /// The Cache Directory Tagging Specification's marker, as `uv` writes it.
        func tag(_ directory: String, signature: String = CacheDirectoryTag.signature) throws {
            let url = home.appendingPathComponent(directory).appendingPathComponent("CACHEDIR.TAG")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data((signature + "\n# This file is a cache directory tag.\n").utf8).write(to: url)
        }

        func scanner() -> SystemCachesScanner {
            SystemCachesScanner(
                cachesRoot: home.appendingPathComponent("Library/Caches"),
                logsRoot: home.appendingPathComponent("Library/Logs"),
                dotCacheRoot: home.appendingPathComponent(".cache")
            )
        }
    }

    @Test("~/.cache is listed by what is in it, never as one row")
    func dotCacheIsListedByChild() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/sometool/index.bin", bytes: 3 * 1024 * 1024)
        try sandbox.file(".cache/runtime/bin/engine", bytes: 5 * 1024 * 1024)
        try sandbox.file(".cache/loose.log", bytes: 2 * 1024 * 1024)

        let result = try await sandbox.scanner().scan(context: ScanContext())

        #expect(result.entries.map(\.url.lastPathComponent) == ["runtime", "sometool", "loose.log"],
                "largest first")
        // The parts are the folder, once.
        let whole = try await AllocatedSizeMeasurer()
            .measure(sandbox.home.appendingPathComponent(".cache"))
        #expect(result.totalBytes == whole.allocatedBytes)
    }

    /// Sitting under `~/.cache` is where a tool *may* put a cache. `CACHEDIR.TAG` is
    /// the tool saying that it has. In this category the difference is not a badge:
    /// it decides what is counted safe and ticked for the user.
    @Test("under ~/.cache only a folder carrying its tool's tag is safe; the rest needs review")
    func safeNeedsTheCacheDirectoryTag() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/tagged/wheels/pkg.whl", bytes: 4 * 1024 * 1024)
        try sandbox.tag(".cache/tagged")
        try sandbox.file(".cache/untagged/bin/engine")
        // Hugging Face tags `hub`, one level down. The row is the whole folder, which
        // also holds logs and a second store, so the row is not the tagged thing.
        try sandbox.file(".cache/models/hub/blobs/weights")
        try sandbox.tag(".cache/models/hub")
        // A file called CACHEDIR.TAG proves nothing; the signature does.
        try sandbox.file(".cache/forged/data.bin")
        try sandbox.tag(".cache/forged", signature: "Signature: not-the-real-one")
        // The system's own cache folder needs no tag: that is what the folder is for.
        try sandbox.file("Library/Caches/com.example.app/blob", bytes: 3 * 1024 * 1024)

        let result = try await sandbox.scanner().scan(context: ScanContext())
        func row(_ name: String) throws -> FileEntry {
            try #require(result.entries.first { $0.url.lastPathComponent == name })
        }

        #expect(try row("tagged").isRegenerable)
        #expect(try row("com.example.app").isRegenerable)
        #expect(try !row("untagged").isRegenerable)
        #expect(try !row("models").isRegenerable)
        #expect(try !row("forged").isRegenerable)

        let safe = Set(result.tileRows(safeToRemove: true).map(\.url.lastPathComponent))
        #expect(safe == ["tagged", "com.example.app"])
        let review = Set(result.tileRows(safeToRemove: false).map(\.url.lastPathComponent))
        #expect(review == ["untagged", "models", "forged"])
        #expect(result.safeToRemoveBytes + result.needsReviewBytes == result.totalBytes)
    }

    @Test("a cache that Package Manager Caches claims is left to it")
    func packageManagerCachesAreSkipped() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/uv/wheels-v6/pkg.whl", bytes: 4 * 1024 * 1024)
        try sandbox.tag(".cache/uv")
        try sandbox.file(".cache/other/blob", bytes: 3 * 1024 * 1024)

        let system = try await sandbox.scanner().scan(context: ScanContext())
        let packages = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())

        #expect(system.entries.map(\.url.lastPathComponent) == ["other"])
        #expect(packages.entries.map(\.displayName) == ["uv cache"])
        #expect(packages.safeToRemoveBytes == packages.totalBytes)
    }

    @Test("an excluded child of ~/.cache is not listed, and the rest still is")
    func excludedChildIsSkipped() async throws {
        let sandbox = try Sandbox()
        let kept = try sandbox.file(".cache/keep/blob").deletingLastPathComponent()
        try sandbox.file(".cache/offer/blob")

        let result = try await sandbox.scanner()
            .scan(context: ScanContext(excludedPaths: [kept.standardizedFileURL.path]))

        #expect(result.entries.map(\.url.lastPathComponent) == ["offer"])
    }

    @Test("a Mac with no ~/.cache is an ordinary Mac")
    func missingDotCacheIsNotAnError() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/com.example.app/blob")

        let result = try await sandbox.scanner().scan(context: ScanContext())

        #expect(result.availability == .available)
        #expect(result.entries.map(\.url.lastPathComponent) == ["com.example.app"])
    }
}
