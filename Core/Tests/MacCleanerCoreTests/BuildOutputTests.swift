import Foundation
import Testing
@testable import MacCleanerCore

/// Build output is recognised by shape and offered as regenerable, wherever the
/// project put it; and a recently used folder is shown with a badge, never hidden.
@Suite("Build output and recency")
struct BuildOutputTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("maccleaner-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 4_096) throws -> URL {
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

        /// One derived-data root as `-derivedDataPath` produces it.
        @discardableResult
        func derivedData(_ relative: String, bytes: Int = 4_096) throws -> URL {
            try file("\(relative)/Build/Products/Debug/app.o", bytes: bytes)
            try file("\(relative)/info.plist", bytes: 64)
            return home.appendingPathComponent(relative)
        }
    }

    // MARK: - Detector

    @Test("derived data, package builds and aggregates are recognised; sources are not")
    func detectorRecognisesShapes() throws {
        let sandbox = try Sandbox()
        let derived = try sandbox.derivedData("Proj/DD")
        let package = try sandbox.file("Proj/Core/.build/workspace-state.json")
            .deletingLastPathComponent()
        // One `build` folder holding a root per scheme, as `-derivedDataPath build/<name>` makes.
        try sandbox.derivedData("Proj/build/Release")
        try sandbox.derivedData("Proj/build/calendar")
        let aggregate = sandbox.home.appendingPathComponent("Proj/build")
        // Looks like source, is source.
        let sources = try sandbox.file("Proj/Sources/main.swift").deletingLastPathComponent()
        // Named `build`, but holding something that is not build output: left alone.
        let decoy = try sandbox.file("Other/build/notes.txt").deletingLastPathComponent()

        #expect(BuildOutputDetector.kind(of: derived) == .xcodeDerivedData)
        #expect(BuildOutputDetector.kind(of: package) == .swiftPackageBuild)
        #expect(BuildOutputDetector.kind(of: aggregate) == .xcodeDerivedData)
        #expect(BuildOutputDetector.kind(of: sources) == nil)
        #expect(BuildOutputDetector.kind(of: decoy) == nil,
                "a name is not evidence — the shape test failed")
    }

    @Test("dependency stores are recognised by name and shape; bare names are not enough")
    func detectorRecognisesDependencyStores() throws {
        let sandbox = try Sandbox()
        let modules = try sandbox.file("Proj/node_modules/left-pad/index.js").deletingLastPathComponent()
            .deletingLastPathComponent()
        let venv = try sandbox.file("Proj/.venv/pyvenv.cfg").deletingLastPathComponent()
        let pods = try sandbox.file("Proj/Pods/Manifest.lock").deletingLastPathComponent()
        try sandbox.file("Rust/Cargo.toml")
        let cargo = try sandbox.file("Rust/target/debug/app").deletingLastPathComponent()
            .deletingLastPathComponent()
        let bareTarget = try sandbox.file("Archery/target/scores.txt").deletingLastPathComponent()
        let bareVenv = try sandbox.file("Other/venv/notes.txt").deletingLastPathComponent()

        #expect(BuildOutputDetector.kind(of: modules) == .dependencyStore("npm dependencies"))
        #expect(BuildOutputDetector.kind(of: venv) == .dependencyStore("Python environment"))
        #expect(BuildOutputDetector.kind(of: pods) == .dependencyStore("CocoaPods dependencies"))
        #expect(BuildOutputDetector.kind(of: cargo) == .dependencyStore("Cargo build output"))
        #expect(BuildOutputDetector.kind(of: bareTarget) == nil, "no Cargo.toml: somebody's folder")
        #expect(BuildOutputDetector.kind(of: bareVenv) == nil, "no pyvenv.cfg: not an environment")
        #expect(BuildOutputDetector.kind(of: modules)?.isXcodeOutput == false)
    }

    @Test("a dependency store becomes a removable child of its project")
    func dependencyStoreBecomesProjectChild() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/old-project/src/index.js", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/old-project/node_modules/big/blob", bytes: 30 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 0))

        let project = try #require(result.entries.first {
            $0.url.lastPathComponent == "old-project"
        })
        let modules = try #require(project.children.first {
            $0.url.lastPathComponent == "node_modules"
        })

        #expect(modules.isRegenerable)
        #expect(modules.kind == .cache)
        #expect(modules.parentDisplay.hasSuffix("npm dependencies"))
        #expect(modules.allocatedBytes >= 30 * 1024 * 1024)
        #expect(!result.entries.contains { $0.url == modules.url })

        #expect(!project.isRegenerable, "the code is the user's")
        #expect(project.allocatedBytes < 10 * 1024 * 1024, "and it no longer carries the modules")
        #expect(project.rowDisplayBytes == project.totalBytesIncludingChildren)
        #expect(result.totalBytes == project.displayBytes)
        #expect(CleanupService.removalTargets(
            for: project,
            removeProtectedAppData: false
        ).map(\.id) == [modules.id, project.id])
    }

    @Test("an excluded dependency store is neither carved nor listed")
    func excludedStoreStaysInsideItsProject() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/proj/src/index.js", bytes: 2 * 1024 * 1024)
        let modules = try sandbox.file("Documents/proj/node_modules/big/blob", bytes: 30 * 1024 * 1024)
            .deletingLastPathComponent().deletingLastPathComponent()

        let result = try await DocumentsFilesScanner(home: sandbox.home).scan(
            context: ScanContext(excludedPaths: [modules.standardizedFileURL.path], protectRecentDays: 0)
        )

        #expect(!result.entries.contains { $0.url == modules })
        // And the project itself is not offered either: a folder that contains an
        // exclusion is never removable, because removing it would remove the
        // excluded store with it. Hands off means the whole project.
        #expect(!result.entries.contains { $0.url.lastPathComponent == "proj" })
    }

    @Test("a bundle in Downloads is a downloaded app, not an installed one")
    func downloadedAppIsAFile() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(
            "Downloads/logioptionsplus_installer.app/Contents/MacOS/installer",
            bytes: 12 * 1024 * 1024
        )

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 0))
        let row = try #require(result.entries.first {
            $0.url.lastPathComponent == "logioptionsplus_installer.app"
        })

        #expect(row.kind == .downloadedApp)
        #expect(row.kind != .appBundle, "only installed applications route to the uninstaller")
        #expect(!row.isRemovalLocked)
        #expect(!CleanupService.alwaysMovesToTrash(row), "it is a file: the Trash setting applies")
    }

    @Test("roots are found up to two levels down and not inside dependency stores")
    func detectorFindsRoots() throws {
        let sandbox = try Sandbox()
        let project = try sandbox.directory("Proj")
        try sandbox.derivedData("Proj/build/Debug")
        try sandbox.file("Proj/Core/.build/workspace-state.json")
        try sandbox.derivedData("Proj/node_modules/pkg/build/x")   // never descended
        try sandbox.derivedData("Proj/a/b/c/build/deep")            // too deep

        let roots = BuildOutputDetector.roots(under: project)

        // `node_modules` is reported as a root of its own and never entered, so
        // the derived data planted inside it is not found.
        #expect(roots.map(\.url.lastPathComponent) == [".build", "build", "node_modules"])
        #expect(roots.map(\.kind) == [
            .swiftPackageBuild, .xcodeDerivedData, .dependencyStore("npm dependencies"),
        ])
    }

    // MARK: - Xcode scanner

    @Test("a project's build folder becomes a regenerable Xcode row")
    func projectBuildOutputIsOffered() async throws {
        let sandbox = try Sandbox()
        let documents = try sandbox.directory("Documents")
        try sandbox.derivedData("Documents/Renewals/build/Release", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/Renewals/App/main.swift")
        try sandbox.file("Documents/Renewals/node_modules/x/y", bytes: 2 * 1024 * 1024)
        let emptyDeveloper = try sandbox.directory("Library/Developer")

        let result = try await XcodeScanner(
            developerRoot: emptyDeveloper, projectRoots: [documents]
        ).scan(context: ScanContext(protectRecentDays: 0))

        let row = try #require(result.entries.first { $0.displayName == "Renewals build output" })
        #expect(row.isRegenerable)
        #expect(row.kind == .cache)
        #expect(row.url.lastPathComponent == "build")
        #expect(row.parentDisplay.hasSuffix("Xcode derived data"))
        #expect(row.allocatedBytes >= 2 * 1024 * 1024)
        #expect(result.safeToRemoveBytes == result.totalBytes)
        #expect(!result.entries.contains { $0.url.lastPathComponent == "node_modules" },
                "dependency stores are Documents' to list, not Xcode's")
    }

    // MARK: - Documents scanner

    @Test("a recently used folder is listed with a badge, not hidden")
    func recentFolderIsListedNotHidden() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/Thesis/draft.txt", bytes: 2 * 1024 * 1024)

        // Default window: 30 days. The fixture was written seconds ago.
        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let row = try #require(result.entries.first { $0.url.lastPathComponent == "Thesis" })

        #expect(row.protectionReason == .recentUse)
        #expect(!row.isRemovalLocked, "information, not a veto: the checkbox works")
        #expect(!row.isRegenerable, "and it is never counted as safe")
    }

    /// The recency filter used to hide these by accident. Now they are refused on
    /// purpose: a Photos library is the user's photographs, not clutter.
    @Test("Apple's media libraries are never offered, however recent")
    func mediaLibrariesAreNeverOffered() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(
            "Pictures/Photos Library.photoslibrary/originals/1/IMG_0001.HEIC",
            bytes: 2 * 1024 * 1024
        )
        try sandbox.file("Music/Music/Media/song.m4a", bytes: 2 * 1024 * 1024)
        try sandbox.file("Movies/TV/Media/episode.m4v", bytes: 2 * 1024 * 1024)
        try sandbox.file("Pictures/Holiday/IMG_0002.HEIC", bytes: 2 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 0))
        let names = Set(result.entries.map(\.url.lastPathComponent))

        #expect(!names.contains("Photos Library.photoslibrary"))
        #expect(!names.contains("Music"))
        #expect(!names.contains("TV"))
        #expect(names.contains("Holiday"), "an ordinary folder beside them is still listed")
    }

    @Test("a project's row no longer carries its build output")
    func buildOutputIsCarvedOutOfTheProject() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/Renewals/App/main.swift", bytes: 3 * 1024 * 1024)
        try sandbox.derivedData("Documents/Renewals/build/Release", bytes: 40 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext(protectRecentDays: 0))
        let row = try #require(result.entries.first { $0.url.lastPathComponent == "Renewals" })

        // The project keeps what the user made; the 40 MB of products left with
        // the Xcode row. Allocation rounds up, so bound rather than equate.
        #expect(row.allocatedBytes >= 3 * 1024 * 1024)
        #expect(row.allocatedBytes < 10 * 1024 * 1024)
    }
}
