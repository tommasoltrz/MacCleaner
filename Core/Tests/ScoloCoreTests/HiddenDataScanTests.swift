import Foundation
import Testing
@testable import ScoloCore

/// `HiddenDataScanner.scan` against a fixture home.
///
/// The scanner had no test of its own until `~/.cache` was split. It took a home
/// from the day it was written, so nothing stood in the way.
@Suite("Hidden & System Data")
struct HiddenDataScanTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-hidden-\(UUID().uuidString)")
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
    }

    /// On 20 Sep 2026 this Mac's `~/.cache` was one 4.07 GB row marked regenerable:
    /// uv's cache (2.0 GB), a Codex runtime with its binaries (1.6 GB) and Hugging
    /// Face models (261 MB) behind a single checkbox.
    @Test("~/.cache is listed by what is in it, never as one row")
    func dotCacheIsListedByChild() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/sometool/index.bin", bytes: 3 * 1024 * 1024)
        try sandbox.file(".cache/runtime/bin/engine", bytes: 5 * 1024 * 1024)
        try sandbox.file(".cache/loose.log", bytes: 2 * 1024 * 1024)

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        let names = result.entries.map(\.url.lastPathComponent)
        #expect(names == ["runtime", "sometool", "loose.log"], "largest first")
        #expect(!result.entries.contains { $0.url.lastPathComponent == ".cache" })
        // The parts are the folder, once.
        let whole = try await AllocatedSizeMeasurer()
            .measure(sandbox.home.appendingPathComponent(".cache"))
        #expect(result.totalBytes == whole.allocatedBytes)
    }

    /// Sitting under `~/.cache` is where a tool *may* put a cache. `CACHEDIR.TAG` is
    /// the tool saying that it has.
    @Test("a folder is called regenerable on its tool's own tag, not on where it sits")
    func regenerableNeedsTheCacheDirectoryTag() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/tagged/wheels/pkg.whl")
        try sandbox.tag(".cache/tagged")
        try sandbox.file(".cache/untagged/bin/engine")
        // Hugging Face tags `hub`, one level down. The row is the whole folder, which
        // also holds logs and a second store, so the row is not the tagged thing.
        try sandbox.file(".cache/models/hub/blobs/weights")
        try sandbox.tag(".cache/models/hub")
        // A file called CACHEDIR.TAG proves nothing; the signature does.
        try sandbox.file(".cache/forged/data.bin")
        try sandbox.tag(".cache/forged", signature: "Signature: not-the-real-one")

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())
        func row(_ name: String) throws -> FileEntry {
            try #require(result.entries.first { $0.url.lastPathComponent == name })
        }

        #expect(try row("tagged").isRegenerable)
        #expect(try !row("untagged").isRegenerable)
        #expect(try !row("models").isRegenerable)
        #expect(try !row("forged").isRegenerable)
        // Review-only, whatever the badge says: nothing here is counted safe.
        #expect(result.safeToRemoveBytes == 0)
    }

    @Test("a cache that Package Manager Caches claims is left to it")
    func packageManagerCachesAreSkipped() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/uv/wheels-v6/pkg.whl", bytes: 4 * 1024 * 1024)
        try sandbox.tag(".cache/uv")
        try sandbox.file(".cache/other/blob", bytes: 3 * 1024 * 1024)

        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())
        let packages = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())

        #expect(hidden.entries.map(\.url.lastPathComponent) == ["other"])
        #expect(packages.entries.map(\.displayName) == ["uv cache"])
        #expect(packages.safeToRemoveBytes == packages.totalBytes)
    }

    @Test("an excluded child of ~/.cache is not listed, and the rest still is")
    func excludedChildIsSkipped() async throws {
        let sandbox = try Sandbox()
        let kept = try sandbox.file(".cache/keep/blob").deletingLastPathComponent()
        try sandbox.file(".cache/offer/blob")

        let result = try await HiddenDataScanner(home: sandbox.home)
            .scan(context: ScanContext(excludedPaths: [kept.standardizedFileURL.path]))

        #expect(result.entries.map(\.url.lastPathComponent) == ["offer"])
    }
}
