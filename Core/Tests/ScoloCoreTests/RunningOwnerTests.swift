import Foundation
import Testing
@testable import ScoloCore

/// A cache whose owner is running is listed and removable, and is not called safe.
///
/// "Regenerable" was judged by what is on disk. On 19 Sep 2026 that judgement took
/// Chrome's `Shared Dictionary` from under a live Chrome, and `www.reddit.com`
/// failed with `ERR_DICTIONARY_LOAD_FAILED` until Chrome was relaunched. These
/// tests hold the general rule that came out of it — see `FileEntry.inUseBy`.
@Suite("Caches under a running application")
struct RunningOwnerTests {

    @Test("Saved owner rules detect newly started owners and release closed owners")
    func savedOwnership() {
        let owner = FileEntry.RunningOwner(name: "Example", bundleIdentifier: "com.example.app", bundlePath: "/Example.app")
        let rules: [FileEntry.OwnerRule] = [
            .bundleIdentifier("com.example.app"), .bundlePath("/Example.app"),
            .bundleIdentifierPrefix("com.example."), .cacheName("com.example.app")
        ]
        for rule in rules {
            let cache = FileEntry(url: URL(fileURLWithPath: "/cache"), kind: .cache,
                                  allocatedBytes: 1, isRegenerable: true, ownerRules: [rule])
            #expect(cache.inUseBy == nil)
            #expect(ScanContext(runningApplications: [owner]).runningOwner(for: cache) == owner)
            #expect(ScanContext().runningOwner(for: cache) == nil)
            let unrelated = FileEntry.RunningOwner(name: "Other", bundleIdentifier: "org.other.app", bundlePath: "/Other.app")
            #expect(ScanContext(runningApplications: [unrelated]).runningOwner(for: cache) == nil)
            let parent = FileEntry(url: URL(fileURLWithPath: "/parent"), kind: .folder,
                                   allocatedBytes: 1, children: [cache])
            #expect(ScanContext(runningApplications: [owner]).runningOwner(for: parent) == owner)
        }
    }


    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-running-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        @discardableResult
        func directory(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func app(_ name: String, bundleID: String) throws -> URL {
            let bundle = home.appendingPathComponent("Applications/\(name).app")
            try file("Applications/\(name).app/Contents/MacOS/\(name)")
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleName": name, "CFBundlePackageType": "APPL",
                                   "CFBundleIdentifier": bundleID],
                format: .xml, options: 0
            )
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            return bundle
        }
    }

    private static func owner(_ name: String, _ identifier: String,
                              path: String = "/nowhere") -> FileEntry.RunningOwner {
        FileEntry.RunningOwner(name: name, bundleIdentifier: identifier, bundlePath: path)
    }

    // MARK: - Whose cache is it

    @Test("a cache folder is matched by identifier, helper suffix, name or vendor")
    func cacheFoldersFindTheirOwner() {
        let context = ScanContext(runningApplications: [
            Self.owner("Google Chrome", "com.google.Chrome"),
            Self.owner("Spotify", "com.spotify.client"),
            Self.owner("Safari", "com.apple.Safari")
        ])
        #expect(context.runningOwner(ofCacheNamed: "com.google.Chrome")?.name == "Google Chrome")
        #expect(context.runningOwner(ofCacheNamed: "com.spotify.client.helper")?.name == "Spotify")
        #expect(context.runningOwner(ofCacheNamed: "Spotify")?.name == "Spotify")
        // Chrome keeps its HTTP cache in `~/Library/Caches/Google`.
        #expect(context.runningOwner(ofCacheNamed: "Google")?.name == "Google Chrome")

        #expect(context.runningOwner(ofCacheNamed: "com.example.other") == nil)
        // A shared prefix is not ownership: `com.spotify.clientele` is someone else.
        #expect(context.runningOwner(ofCacheNamed: "com.spotify.clientele") == nil)
        // Something from Apple is always running; none of it owns a folder `Apple`.
        #expect(context.runningOwner(ofCacheNamed: "Apple") == nil)
    }

    @Test("running owners also count as running paths")
    func ownersFeedTheRunningPaths() {
        let context = ScanContext(runningApplications: [
            Self.owner("Fixture", "com.example.fixture", path: "/Applications/Fixture.app")
        ])
        #expect(context.runningApplicationPaths.contains("/Applications/Fixture.app"))
    }

    // MARK: - Scanners

    @Test("a running application's cache is listed, removable, and not safe")
    func runningApplicationCacheIsNotSafe() async throws {
        let sandbox = try Sandbox()
        let live = try sandbox.app("Live", bundleID: "com.example.live")
        try sandbox.app("Idle", bundleID: "com.example.idle")
        try sandbox.file("Library/Caches/com.example.live/cache.bin")
        try sandbox.file("Library/Caches/com.example.idle/cache.bin")

        let scanner = ApplicationsScanner(
            applicationDirectories: [sandbox.home.appendingPathComponent("Applications")],
            home: sandbox.home
        )
        let result = try await scanner.scan(context: ScanContext(runningApplications: [Self.owner("Live", "com.example.live", path: live.path)]
        ))

        let liveRow = result.entries.first { $0.displayName == "Live" }
        let idleRow = result.entries.first { $0.displayName == "Idle" }
        let foundLive = liveRow?.children.first { $0.isRegenerable }
        let foundIdle = idleRow?.children.first { $0.isRegenerable }
        let liveCache = try #require(foundLive)
        let idleCache = try #require(foundIdle)
        #expect(liveCache.inUseBy?.name == "Live")
        // Information, not a veto: the checkbox still works.
        #expect(!liveCache.isRemovalLocked)
        #expect(idleCache.inUseBy == nil)

        // Only the idle app's cache is safe, and the two tiles still partition.
        let safe = result.tileRows(safeToRemove: true).map(\.url.path)
        #expect(safe == [idleCache.url.path])
        #expect(result.safeToRemoveBytes == idleCache.allocatedBytes)
        let review = result.tileRows(safeToRemove: false)
        #expect(review.flatMap(\.children).contains { $0.url == liveCache.url })
        #expect(result.safeToRemoveBytes + result.needsReviewBytes
                == result.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("a system cache whose owner runs moves from Safe to Remove to Needs Review")
    func systemCacheUnderRunningOwner() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Caches/com.example.live/data")
        try sandbox.file("Library/Caches/com.example.idle/data")
        let scanner = SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: try sandbox.directory("Library/Logs")
        )

        let result = try await scanner.scan(context: ScanContext(runningApplications: [Self.owner("Live", "com.example.live")]
        ))

        let foundLive = result.entries.first { $0.url.lastPathComponent == "com.example.live" }
        let foundIdle = result.entries.first { $0.url.lastPathComponent == "com.example.idle" }
        let live = try #require(foundLive)
        let idle = try #require(foundIdle)
        #expect(live.inUseBy?.name == "Live")
        #expect(live.isRegenerable, "still regenerable — it is `safe` that is withdrawn")
        #expect(result.safeToRemoveBytes == idle.allocatedBytes)
        #expect(result.needsReviewBytes == live.allocatedBytes)

        // Quit the owner, scan again, and the same folder is safe.
        let after = try await scanner.scan(context: ScanContext())
        #expect(after.needsReviewBytes == 0)
        #expect(after.safeToRemoveBytes == live.allocatedBytes + idle.allocatedBytes)
    }

    @Test("an open Xcode withdraws safe from derived data; a booted Simulator from its own")
    func xcodeRowsUnderRunningTools() async throws {
        let sandbox = try Sandbox()
        let developer = try sandbox.directory("Library/Developer")
        try sandbox.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o")
        try sandbox.file("Library/Developer/CoreSimulator/Caches/dyld/cache")
        let scanner = XcodeScanner(
            developerRoot: developer,
            projectRoots: [],
            systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators")
        )

        let idle = try await scanner.scan(context: ScanContext())
        #expect(!idle.entries.isEmpty)
        #expect(idle.entries.allSatisfy { $0.inUseBy == nil })

        let simulatorOnly = try await scanner.scan(context: ScanContext(runningApplications: [Self.owner("Simulator", "com.apple.iphonesimulator")]
        ))
        for entry in simulatorOnly.entries {
            let isSimulatorData = entry.url.path.contains("/CoreSimulator")
            #expect((entry.inUseBy?.name == "Simulator") == isSimulatorData, "\(entry.url.path)")
        }
        #expect(simulatorOnly.entries.contains { $0.inUseBy != nil })

        let xcode = try await scanner.scan(context: ScanContext(runningApplications: [Self.owner("Xcode", "com.apple.dt.Xcode")]
        ))
        #expect(xcode.entries.allSatisfy { $0.inUseBy?.name == "Xcode" })
        #expect(xcode.safeToRemoveBytes == 0)
    }
}
