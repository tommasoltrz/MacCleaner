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
            .scan(context: ScanContext(protectRecentDays: 0))

        // Largest first, which is the order the list is drawn in.
        #expect(result.entries.map(\.displayName) == ["Homebrew cache", "Gradle cache"])
        #expect(result.entries.allSatisfy { $0.isRegenerable })
        #expect(result.totalBytes >= 4 * 1024 * 1024)
    }

    @Test("recency does not hide a cache written this morning")
    func recencyDoesNotHideACache() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/Homebrew/downloads/bottle.tar.gz")

        // The fixture is minutes old, so a shield that applied here would hide it —
        // and it is exactly the busy caches that are worth the most.
        let result = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 30))

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
                    .deletingLastPathComponent().path],
                protectRecentDays: 0
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
            context: ScanContext(excludedPatterns: ["*.keychain-db"], protectRecentDays: 0)
        )

        #expect(result.entries.map(\.displayName) == ["Gradle cache"])
    }

    @Test("a home with no package manager caches is empty, not unavailable")
    func nothingInstalledIsEmpty() async throws {
        let sandbox = try Sandbox()

        let result = try await PackageManagerScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 0))

        // No daemon to be missing here, so there is nothing to tell the user to fix.
        #expect(result.availability == .empty)
    }
}
