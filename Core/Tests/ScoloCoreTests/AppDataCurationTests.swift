import Foundation
import Testing
@testable import ScoloCore

/// The curation table decides which of an app's support files the user may throw
/// away and which hold their logins. Both directions of that decision are worth a
/// test: a cache that stays listed as user data wastes disk, and user data listed
/// as a cache costs the user their sessions.
///
/// Every case builds a fake home directory, so the assertions hold on any Mac
/// rather than depending on which apps happen to be installed.
@Suite("App data curation")
struct AppDataCurationTests {

    // MARK: - Fixture helpers

    /// A temporary directory removed when the test finishes.
    private final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("scolo-curation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func writeFile(_ relativePath: String, bytes: Int) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        @discardableResult
        func directory(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private static let oneMB = 1024 * 1024

    /// `~/Library/Application Support/<name>` inside a sandbox home.
    private static func support(_ name: String) -> String {
        "Library/Application Support/\(name)"
    }

    private static func curated(
        _ curation: ApplicationsScanner.AppDataCuration,
        home: URL,
        context: ScanContext = ScanContext()
    ) async throws -> ApplicationsScanner.CuratedData {
        let result = try await ApplicationsScanner.curatedChildren(
            curation, home: home, context: context
        )
        return try #require(result)
    }

    private static func remainder(
        _ data: ApplicationsScanner.CuratedData
    ) -> FileEntry? {
        data.entries.first { $0.protectionReason == .userData }
    }

    // MARK: - The Electron rule

    @Test("a support folder holding Code Cache is curated without a table entry")
    func electronMarkerTriggersCuration() throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Fixture")
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: 1024)
        try sandbox.writeFile("\(folder)/Cookies", bytes: 1024)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.example.fixture", baseName: "Fixture", home: sandbox.root
        ))

        #expect(curation.root == folder)
        #expect(curation.regenerable == ApplicationsScanner.electronRegenerable)
        // The name has to read as a warning, not as a folder name.
        #expect(curation.remainderName == "Fixture settings and data")
    }

    /// The folder is found the same two ways `leftoverCandidates` finds it, and
    /// apps disagree about which one they use.
    @Test("the marker is looked for under the bundle identifier as well as the app name")
    func electronFolderFoundByBundleIdentifier() throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile(Self.support("com.example.fixture/GPUCache/data"), bytes: 1024)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.example.fixture", baseName: "Fixture", home: sandbox.root
        ))

        #expect(curation.root == Self.support("com.example.fixture"))
        // The row is named after the app, never after the folder.
        #expect(curation.remainderName == "Fixture settings and data")
    }

    @Test("a support folder with no Chromium markers is left alone")
    func nonElectronFolderIsNotCurated() throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Plain")
        try sandbox.writeFile("\(folder)/Local Storage/leveldb/CURRENT", bytes: 1024)
        try sandbox.writeFile("\(folder)/Preferences", bytes: 1024)
        try sandbox.writeFile("\(folder)/Cache/blob", bytes: 1024)

        // `Cache` alone is not a marker: plenty of native apps keep one, and
        // curating them on that basis would invent knowledge nobody has.
        let curation = ApplicationsScanner.curation(
            bundleID: "com.example.plain", baseName: "Plain", home: sandbox.root
        )

        #expect(curation == nil)
    }

    @Test("an app with no support folder at all is not curated")
    func missingFolderIsNotCurated() throws {
        let sandbox = try Sandbox()
        try sandbox.directory(Self.support("Somebody Else"))

        #expect(ApplicationsScanner.curation(
            bundleID: "com.example.absent", baseName: "Absent", home: sandbox.root
        ) == nil)
    }

    @Test("Session Storage is not treated as a cache")
    func sessionStorageStaysUserData() {
        // It holds what the user had open, so it belongs in the locked entry.
        #expect(!ApplicationsScanner.electronRegenerable.contains("Session Storage"))
        #expect(!ApplicationsScanner.electronRegenerable.contains("Local Storage"))
        #expect(!ApplicationsScanner.electronRegenerable.contains("IndexedDB"))
    }

    // MARK: - Explicit table beats the generic rule

    @Test("a table entry wins over the Electron marker")
    func explicitCurationBeatsGeneric() throws {
        let sandbox = try Sandbox()
        // Chrome's real folder, plus a decoy named after the bundle identifier
        // carrying the marker the generic rule looks for.
        try sandbox.writeFile(
            Self.support("Google/Chrome/Default/Code Cache/index"), bytes: 1024
        )
        try sandbox.writeFile(
            Self.support("com.google.Chrome/Code Cache/index"), bytes: 1024
        )

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.google.Chrome", baseName: "Google Chrome", home: sandbox.root
        ))

        #expect(curation.root == Self.support("Google/Chrome"))
        #expect(curation.remainderName == "Chrome profiles and settings")
        #expect(curation.regenerable != ApplicationsScanner.electronRegenerable)
    }

    /// A table entry names a path that need not exist here. Returning it anyway
    /// would make the scanner measure a folder that is not there.
    @Test("a table entry whose folder is missing curates nothing")
    func explicitCurationNeedsItsFolder() throws {
        let sandbox = try Sandbox()
        try sandbox.directory(Self.support("Google"))

        #expect(ApplicationsScanner.curation(
            bundleID: "com.google.Chrome", baseName: "Google Chrome", home: sandbox.root
        ) == nil)
    }

    @Test("known app identifiers route to their observed support folders")
    func knownAppSupportFoldersStayExplicit() throws {
        let sandbox = try Sandbox()
        let cases = [
            ("com.microsoft.VSCode", "Visual Studio Code", "Code"),
            ("com.openai.codex", "ChatGPT", "Codex"),
            ("com.figma.Desktop", "Figma", "Figma"),
            ("org.ferdium.ferdium-app", "Ferdium", "Ferdium"),
            ("org.torproject.torbrowser", "Tor Browser", "TorBrowser-Data"),
        ]

        for (bundleID, appName, supportName) in cases {
            let expectedRoot = Self.support(supportName)
            try sandbox.directory(expectedRoot)
            let curation = try #require(ApplicationsScanner.curation(
                bundleID: bundleID, baseName: appName, home: sandbox.root
            ))
            #expect(curation.root == expectedRoot)
        }
    }

    // MARK: - Remainder arithmetic

    @Test("the locked remainder is the measured folder minus the curated bytes")
    func remainderIsMeasuredNotGuessed() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Fixture")
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: 2 * Self.oneMB)
        try sandbox.writeFile("\(folder)/GPUCache/data", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Local Storage/leveldb/CURRENT", bytes: 4 * Self.oneMB)
        try sandbox.writeFile("\(folder)/Cookies", bytes: Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "Fixture", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        let caches = data.entries.filter(\.isRegenerable)
        #expect(caches.count == 2)
        #expect(caches.allSatisfy { $0.kind == .cache })

        let locked = try #require(Self.remainder(data))
        #expect(locked.isRemovalLocked)
        #expect(locked.displayName == "Fixture settings and data")

        let whole = try await AllocatedSizeMeasurer()
            .measure(sandbox.root.appendingPathComponent(folder))
        let curatedBytes = caches.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(locked.allocatedBytes == whole.allocatedBytes - curatedBytes)

        // The halves partition the folder: neither claims a byte of the other.
        #expect(curatedBytes + locked.allocatedBytes == whole.allocatedBytes)
    }

    @Test("a folder that is all cache leaves no remainder entry")
    func remainderFloorsAtZero() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("AllCache")
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/GPUCache/data", bytes: Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "AllCache", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        #expect(data.entries.count == 2)
        // Nothing is left, so no locked row is invented and no negative figure
        // can reach the UI.
        #expect(Self.remainder(data) == nil)
    }

    /// This test used to assert something weaker and wrong: that an excluded cache
    /// is merely left out of the offered entries while its bytes rest in the locked
    /// remainder. They do — but the remainder travels with the application bundle,
    /// so removing the app deleted the excluded folder anyway. An exclusion means
    /// "never touch this", so it now protects the whole application.
    @Test("an excluded cache protects the whole application")
    func exclusionOutranksCuration() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Fixture")
        let excluded = try sandbox.directory("\(folder)/Code Cache")
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: 2 * Self.oneMB)
        try sandbox.writeFile("\(folder)/GPUCache/data", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Cookies", bytes: Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "Fixture", home: sandbox.root
        ))
        let context = ScanContext(excludedPaths: [excluded.standardizedFileURL.path])
        let data = try await Self.curated(curation, home: sandbox.root, context: context)

        #expect(data.holdsProtectedContent)
        // Nothing from this folder is offered — not the excluded cache, and not the
        // siblings that would have gone with the bundle.
        #expect(data.entries.isEmpty)
    }

    @Test("a service worker's caches are offered; its registration is not")
    func serviceWorkerCachesAreSplitFromTheRegistration() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Google/Chrome")
        try sandbox.writeFile(
            "\(folder)/Default/Service Worker/CacheStorage/x", bytes: Self.oneMB
        )
        try sandbox.writeFile(
            "\(folder)/Default/Service Worker/ScriptCache/y", bytes: Self.oneMB
        )
        try sandbox.writeFile("\(folder)/Default/Shared Dictionary/db", bytes: Self.oneMB)
        // The registration itself, and the user's logins beside it.
        try sandbox.writeFile(
            "\(folder)/Default/Service Worker/Database/000003.log", bytes: 2 * Self.oneMB
        )
        try sandbox.writeFile("\(folder)/Default/Cookies", bytes: Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.google.Chrome", baseName: "Google Chrome", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        let offered = Set(data.entries.map(\.url.lastPathComponent))
        #expect(offered.contains("CacheStorage"))
        #expect(offered.contains("ScriptCache"))
        #expect(offered.contains("Shared Dictionary"))
        #expect(!offered.contains("Database"),
                "the registration is what makes an installed web app work")

        // Database and Cookies, and nothing that regenerates.
        let locked = try #require(Self.remainder(data))
        #expect(locked.allocatedBytes >= 3 * Int64(Self.oneMB))
        #expect(locked.allocatedBytes < 4 * Int64(Self.oneMB))
    }

    @Test("an Electron app's script cache and dictionaries are offered too")
    func electronAppsGetTheSameTwoCaches() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Fixture")
        // The marker that makes this an Electron layout at all.
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Service Worker/ScriptCache/y", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Shared Dictionary/db", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Local Storage/leveldb/CURRENT", bytes: Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.example.fixture", baseName: "Fixture", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        let offered = Set(data.entries.map(\.url.lastPathComponent))
        #expect(offered.isSuperset(of: ["Code Cache", "ScriptCache", "Shared Dictionary"]))

        // Local Storage is the user's, and stays locked.
        let locked = try #require(Self.remainder(data))
        #expect(locked.allocatedBytes >= Int64(Self.oneMB))
    }

    // MARK: - Glob expansion

    @Test("one glob level reaches every profile the user made")
    func globReachesEveryProfile() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Google/Chrome")
        try sandbox.writeFile("\(folder)/Default/Code Cache/index", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Profile 1/GPUCache/data", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Profile 2/Service Worker/CacheStorage/x", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Default/History", bytes: 3 * Self.oneMB)

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.google.Chrome", baseName: "Google Chrome", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        let paths = Set(data.entries.map(\.url.path))
        for profileCache in ["Default/Code Cache", "Profile 1/GPUCache",
                             "Profile 2/Service Worker/CacheStorage"] {
            #expect(paths.contains(
                sandbox.root.appendingPathComponent("\(folder)/\(profileCache)").path
            ))
        }

        // History is the user's browsing, so it stays in the locked entry.
        let locked = try #require(Self.remainder(data))
        #expect(locked.allocatedBytes >= 3 * Int64(Self.oneMB))
    }

    @Test("a glob that matches nothing expands to nothing")
    func globWithoutMatchesIsHarmless() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.directory("Chrome")
        try sandbox.directory("Chrome/Default")

        #expect(ApplicationsScanner.expand("Profile */Code Cache", under: root).isEmpty)
        // A literal component is appended without reading the directory, so it
        // still yields a path even when nothing is there.
        #expect(ApplicationsScanner.expand("Default/Code Cache", under: root).count == 1)
    }

    /// Claude Desktop keeps its renderers in per-feature partitions, which is why
    /// the marker test cannot see them and the table carries an entry.
    @Test("Claude Desktop's partition caches are reached through the table")
    func claudeDesktopPartitionsAreCurated() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Claude")
        try sandbox.writeFile("\(folder)/Partitions/preview-a/Code Cache/index", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Partitions/preview-b/Cache/data", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/Cookies", bytes: Self.oneMB)
        try sandbox.writeFile("\(folder)/claude-code/2.1.0/bundle", bytes: 4 * Self.oneMB)

        // The generic rule genuinely cannot help here: there is no marker on top.
        #expect(!ApplicationsScanner.electronMarkers.contains {
            FileManager.default.fileExists(
                atPath: sandbox.root.appendingPathComponent("\(folder)/\($0)").path
            )
        })

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: "com.anthropic.claudefordesktop", baseName: "Claude", home: sandbox.root
        ))
        let data = try await Self.curated(curation, home: sandbox.root)

        #expect(data.entries.filter(\.isRegenerable).count == 2)
        let locked = try #require(Self.remainder(data))
        #expect(locked.displayName == "Claude settings and data")
        // The installed CLI is not a cache and stays locked with the rest.
        #expect(locked.allocatedBytes >= 4 * Int64(Self.oneMB))
    }

    // MARK: - Overlap guard

    @Test("a curated folder and a leftover candidate never both claim a path")
    func overlapIsDetectedInBothDirections() {
        #expect(ApplicationsScanner.overlaps("/a/b", "/a/b"))
        #expect(ApplicationsScanner.overlaps("/a/b/c", "/a/b"))
        #expect(ApplicationsScanner.overlaps("/a/b", "/a/b/c"))
        // Component-aware: a sibling with a longer name is a different folder.
        #expect(!ApplicationsScanner.overlaps("/a/bc", "/a/b"))
    }

    // MARK: - Cancellation

    @Test("cancellation is honoured while curating")
    func cancellationHonoured() async throws {
        let sandbox = try Sandbox()
        let folder = Self.support("Fixture")
        try sandbox.writeFile("\(folder)/Code Cache/index", bytes: 1024)
        for index in 0..<500 {
            try sandbox.writeFile("\(folder)/Cache/file-\(index).bin", bytes: 1024)
        }

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "Fixture", home: sandbox.root
        ))
        let home = sandbox.root
        let task = Task {
            try await ApplicationsScanner.curatedChildren(
                curation, home: home, context: ScanContext()
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
