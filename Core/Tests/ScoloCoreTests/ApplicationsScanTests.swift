import Foundation
import Testing
@testable import ScoloCore

/// `ApplicationsScanner.scan` against planted application bundles.
///
/// Until its search roots became injectable this could not be written at all: the
/// scanner read `/Applications` and the real `~/Library` from compiled-in absolute
/// paths, so every assertion about a result was an assertion about the machine
/// running the suite. Only the static curation helpers were covered, which is the
/// half that decides how an app's data is *split* — never the half that decides
/// whether an application is offered for removal in the first place.
@Suite("Applications are offered with their leftovers")
struct ApplicationsScanTests {

    // MARK: - Fixture

    private final class Sandbox {
        /// Stands in for the user's home; `Library` beneath it holds the leftovers.
        let home: URL
        let applications: URL

        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-apps-\(UUID().uuidString)")
            applications = home.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(
                at: applications, withIntermediateDirectories: true
            )
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        /// A bundle real enough for `Bundle(url:)` to read an identifier out of it.
        @discardableResult
        func app(_ name: String, bundleID: String?, bytes: Int = 2 * 1024 * 1024) throws -> URL {
            let bundle = applications.appendingPathComponent("\(name).app", isDirectory: true)
            let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: macOS.appendingPathComponent(name))

            var plist: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
            if let bundleID { plist["CFBundleIdentifier"] = bundleID }
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            return bundle
        }

        /// A file under the fixture home, parents created as needed.
        @discardableResult
        func file(_ relative: String, bytes: Int = 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }

        /// A scanner that can see nothing but this fixture. Both roots are passed:
        /// `home` alone would leave the real `/Applications` in the search.
        func scanner() -> ApplicationsScanner {
            ApplicationsScanner(applicationDirectories: [applications], home: home)
        }
    }

    /// Recency is off by default here. A fixture is written milliseconds before it is
    /// scanned, so every planted app is "used today" and would carry a `.recentUse`
    /// badge — true, and noise in every test but the one that asserts it.
    private func context(
        excludedPaths: [String] = [],
        excludedPatterns: [String] = [],
        protectRecentDays: Int = 0,
        running: Set<String> = []
    ) -> ScanContext {
        ScanContext(
            excludedPaths: excludedPaths,
            excludedPatterns: excludedPatterns,
            protectRecentDays: protectRecentDays,
            runningApplicationPaths: running
        )
    }

    // MARK: - The ordinary case

    @Test("an application is one row carrying its leftovers as children")
    func applicationCarriesItsLeftovers() async throws {
        let sandbox = try Sandbox()
        try sandbox.app("Fixture", bundleID: "com.example.fixture")
        try sandbox.file("Library/Application Support/com.example.fixture/data.bin")
        try sandbox.file("Library/Caches/com.example.fixture/cache.bin")
        try sandbox.file("Library/Preferences/com.example.fixture.plist", bytes: 4_096)

        let result = try await sandbox.scanner().scan(context: context())

        let row = try #require(result.entries.first)
        // Finder hides the extension, so the row does too.
        #expect(row.displayName == "Fixture")
        #expect(row.kind == .appBundle)
        #expect(row.allocatedBytes >= 2 * 1024 * 1024)

        let children = Set(row.children.map(\.url.lastPathComponent))
        #expect(children == ["com.example.fixture", "com.example.fixture.plist"])
        #expect(row.childCount == row.children.count)
        // The headline figure is the bundle plus everything that goes with it.
        #expect(row.totalBytesIncludingChildren >= 4 * 1024 * 1024)
    }

    @Test("a cache regenerates; support and preferences are the user's own data")
    func leftoversCarryTheRightDisposition() async throws {
        let sandbox = try Sandbox()
        try sandbox.app("Fixture", bundleID: "com.example.fixture")
        try sandbox.file("Library/Application Support/com.example.fixture/data.bin")
        try sandbox.file("Library/Caches/com.example.fixture/cache.bin")

        let result = try await sandbox.scanner().scan(context: context())
        let row = try #require(result.entries.first)

        let cache = try #require(row.children.first { $0.url.path.contains("/Caches/") })
        let support = try #require(
            row.children.first { $0.url.path.contains("/Application Support/") }
        )
        #expect(cache.isRegenerable)
        #expect(!support.isRegenerable)
        // A support folder is the user's data whether the app ran today or in 2019,
        // so deleting the child on its own has to warn even when the app row does not.
        #expect(support.protectionReason == .userData)
        #expect(cache.protectionReason == nil)
    }

    // MARK: - Rules that keep an application off the list

    @Test("an excluded application is not walked, listed or counted")
    func excludedApplicationIsNotOffered() async throws {
        let sandbox = try Sandbox()
        let excluded = try sandbox.app("Excluded", bundleID: "com.example.excluded")
        try sandbox.app("Ordinary", bundleID: "com.example.ordinary")
        try sandbox.file("Library/Caches/com.example.excluded/cache.bin")

        let result = try await sandbox.scanner()
            .scan(context: context(excludedPaths: [excluded.path]))

        #expect(result.entries.map(\.displayName) == ["Ordinary"])
        // Not merely hidden from the list: its bytes are not in the total either.
        #expect(result.totalBytes < 3 * 1024 * 1024)
    }

    @Test("an application shipping a protected pattern is not offered at all")
    func applicationHoldingAProtectedPatternIsWithheld() async throws {
        let sandbox = try Sandbox()
        let guarded = try sandbox.app("Guarded", bundleID: "com.example.guarded")
        try Data(count: 1024).write(
            to: guarded.appendingPathComponent("Contents/Secrets.keychain-db")
        )
        try sandbox.app("Ordinary", bundleID: "com.example.ordinary")

        let result = try await sandbox.scanner()
            .scan(context: context(excludedPatterns: ["*.keychain-db"]))

        #expect(result.entries.map(\.displayName) == ["Ordinary"],
                "removing the row would take the keychain with it")
    }

    @Test("a protected leftover is left out while its application stays listed")
    func protectedLeftoverIsNotOfferedWithTheApplication() async throws {
        let sandbox = try Sandbox()
        try sandbox.app("Fixture", bundleID: "com.example.fixture")
        try sandbox.file(
            "Library/Application Support/com.example.fixture/Secrets.keychain-db", bytes: 1024
        )
        try sandbox.file("Library/Caches/com.example.fixture/cache.bin")

        let result = try await sandbox.scanner()
            .scan(context: context(excludedPatterns: ["*.keychain-db"]))

        let row = try #require(result.entries.first)
        // The app is still worth listing — the folder holding the keychain simply is
        // not on the list, so removing the row cannot take it.
        #expect(row.children.map(\.url.lastPathComponent) == ["com.example.fixture"])
        #expect(row.children.allSatisfy { $0.url.path.contains("/Caches/") })
    }

    // MARK: - Protection, which locks a row rather than hiding it

    @Test("a running application is listed with its checkbox locked")
    func runningApplicationIsProtectedNotHidden() async throws {
        let sandbox = try Sandbox()
        let running = try sandbox.app("Running", bundleID: "com.example.running")

        let result = try await sandbox.scanner()
            .scan(context: context(running: [running.path]))

        let row = try #require(result.entries.first)
        #expect(row.displayName == "Running")
        #expect(row.protectionReason == .running)
    }

    @Test("a recently used application is badged, never hidden")
    func recentApplicationIsBadged() async throws {
        let sandbox = try Sandbox()
        try sandbox.app("Fresh", bundleID: "com.example.fresh")

        // The fixture was written a moment ago, so any window at all contains it.
        let result = try await sandbox.scanner()
            .scan(context: context(protectRecentDays: 30))

        let row = try #require(result.entries.first)
        #expect(row.protectionReason == .recentUse)
        #expect(row.allocatedBytes > 0, "recency is a badge, not a filter")
    }

    // MARK: - Reporting what could not be read

    @Test("an unreadable application folder is a repair message, not an empty list")
    func unreadableRootReportsUnavailable() async throws {
        let sandbox = try Sandbox()
        let scanner = ApplicationsScanner(
            applicationDirectories: [sandbox.home.appendingPathComponent("Nowhere")],
            home: sandbox.home
        )

        let result = try await scanner.scan(context: context())

        guard case .unavailable(let reason) = result.availability else {
            Issue.record("expected .unavailable, got \(result.availability)")
            return
        }
        #expect(reason.contains("Full Disk Access"))
        #expect(result.entries.isEmpty)
    }

    @Test("a folder with no applications in it is empty, not unavailable")
    func readableButEmptyRootIsEmpty() async throws {
        let sandbox = try Sandbox()

        let result = try await sandbox.scanner().scan(context: context())

        #expect(result.availability == .empty)
        #expect(result.entries.isEmpty)
    }

    // MARK: - Order

    @Test("the least recently used application sorts first")
    func leastRecentlyUsedSortsFirst() async throws {
        let sandbox = try Sandbox()
        let old = try sandbox.app("Ancient", bundleID: "com.example.ancient")
        try sandbox.app("Current", bundleID: "com.example.current")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path
        )

        let result = try await sandbox.scanner().scan(context: context())

        #expect(result.entries.map(\.displayName) == ["Ancient", "Current"])
    }
}
