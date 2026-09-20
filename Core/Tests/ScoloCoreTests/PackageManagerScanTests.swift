import Foundation
import Testing
@testable import ScoloCore

/// `PackageManagerScanner.scan` against a fixture home.
///
/// The roots are declared as path components relative to a home, which is now
/// injected, so the rules can be exercised without depending on which package
/// managers happen to be installed on the machine running the suite.
@Suite("Package manager caches")
struct PackageManagerScanTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-pkg-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }
    }

    @Test("a planted cache is offered under its tool's name, as regenerable")
    func plantedCachesAreOffered() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 3 * 1024 * 1024)
        try sandbox.file(".gradle/caches/modules-2/thing.jar")

        let result = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())

        // Largest first, which is the order the list is drawn in.
        #expect(result.entries.map(\.displayName) == ["Homebrew cache", "Gradle cache"])
        #expect(result.entries.allSatisfy { $0.isRegenerable })
        #expect(result.totalBytes >= 4 * 1024 * 1024)
    }

    /// `~/.cargo` was left out whole because it holds a toolchain. The cache inside
    /// it is a cache all the same, and the toolchain beside it is nobody's to offer.
    @Test("a cache inside a toolchain folder is offered; the toolchain is offered by no one")
    func cacheInsideAToolchainFolder() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cargo/registry/cache/index/serde.crate", bytes: 8 * 1024 * 1024)
        try sandbox.file(".cargo/bin/ripgrep", bytes: 7 * 1024 * 1024)
        try sandbox.file(".pub-cache/hosted/pub.dev/http/lib.dart", bytes: 6 * 1024 * 1024)
        try sandbox.file(".pub-cache/bin/activated-tool", bytes: 6 * 1024 * 1024)
        // Control: a dot-folder no package manager claims is still Hidden Data's.
        try sandbox.file(".somebody/data.bin", bytes: 6 * 1024 * 1024)

        let packages = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let hidden = try await HiddenDataScanner(home: sandbox.home)
            .scan(context: ScanContext())

        #expect(packages.entries.map(\.displayName) == ["Cargo registry", "Dart pub cache"])
        #expect(packages.entries.allSatisfy { $0.isRegenerable })
        let offered = (packages.entries + hidden.entries).map(\.url.path)
        #expect(!offered.contains { $0.hasSuffix("/.cargo") || $0.contains("/.cargo/bin") })
        #expect(!offered.contains { $0.hasSuffix("/.pub-cache") || $0.contains("/.pub-cache/bin") })
        #expect(hidden.entries.contains { $0.url.lastPathComponent == ".somebody" })
    }

    @Test("a cache that moved here from System Caches is offered once, under its tool's name")
    func relabelledCacheIsOfferedOnce() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/org.swift.swiftpm/repositories/pkg/pack", bytes: 4 * 1024 * 1024)
        try sandbox.file("Library/Caches/com.example.other/blob", bytes: 2 * 1024 * 1024)
        try FileManager.default.createDirectory(
            at: sandbox.home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true
        )

        let packages = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let system = try await SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: sandbox.home.appendingPathComponent("Library/Logs")
        ).scan(context: ScanContext())

        #expect(packages.entries.map(\.displayName) == ["SwiftPM cache"])
        #expect(system.entries.map(\.url.lastPathComponent) == ["com.example.other"])
    }

    @Test("recency does not hide a cache written this morning")
    func recencyDoesNotHideACache() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/Homebrew/downloads/bottle.tar.gz")

        // The fixture is minutes old, so a date filter would hide it — and it is
        // exactly the busy caches that are worth the most.
        let result = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())

        let row = try #require(result.entries.first)
        #expect(row.displayName == "Homebrew cache")
        #expect(row.protectionReason == nil)
    }

    @Test("an excluded cache root is not offered")
    func excludedRootIsSkipped() async throws {
        let sandbox = try Sandbox()
        let excluded = try sandbox.file("Library/Caches/Homebrew/downloads/bottle.tar.gz")
        try sandbox.file(".gradle/caches/modules-2/thing.jar")

        let result = try await PackageManagerScanner(home: sandbox.home).scan(
            context: ScanContext(
                excludedPaths: [excluded.deletingLastPathComponent()
                    .deletingLastPathComponent().path]
            )
        )

        #expect(result.entries.map(\.displayName) == ["Gradle cache"])
    }

    @Test("a cache root holding a protected pattern is not offered")
    func protectedPatternWithholdsARoot() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/Homebrew/downloads/Secrets.keychain-db", bytes: 1024)
        try sandbox.file(".gradle/caches/modules-2/thing.jar")

        let result = try await PackageManagerScanner(home: sandbox.home).scan(
            context: ScanContext(excludedPatterns: ["*.keychain-db"])
        )

        #expect(result.entries.map(\.displayName) == ["Gradle cache"])
    }

    @Test("a home with no package manager caches is empty, not unavailable")
    func nothingInstalledIsEmpty() async throws {
        let sandbox = try Sandbox()

        let result = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext())

        // No daemon to be missing here, so there is nothing to tell the user to fix.
        #expect(result.availability == .empty)
    }
}
