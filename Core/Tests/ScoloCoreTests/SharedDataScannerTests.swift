import Foundation
import Testing
@testable import ScoloCore

@Suite("Shared Data scanning")
struct SharedDataScannerTests {
    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("scolo-shared-data-\(UUID().uuidString)").standardizedFileURL
        var shared: URL { home.appendingPathComponent("Shared") }
        var apps: URL { home.appendingPathComponent("Applications") }
        init() throws {
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }
        @discardableResult
        func file(_ path: String) throws -> URL {
            let url = shared.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 8192).write(to: url)
            return url
        }
        func app(_ url: URL, id: String) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        func scan(_ context: ScanContext = ScanContext()) async throws -> ScanCategoryResult {
            try await SharedDataScanner(root: shared, applicationRoots: [apps]).scan(context: context)
        }
    }

    @Test("unknown shared folders appear only for review")
    func unknownFolders() async throws {
        let fixture = try Fixture()
        try fixture.file("Old Export/data")
        try fixture.file("notes.txt")
        let result = try await fixture.scan()
        #expect(result.entries.count == 2)
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.needsReviewBytes == result.totalBytes)
        #expect(result.entries.allSatisfy { !$0.isRegenerable && !$0.isRemovalLocked })
        #expect(result.entries.allSatisfy { $0.safetyCaveat == "Owner unknown. Review before removal." })
        #expect(CleanupSelection.ids(in: [result], selected: Set(result.entries.map(\.id)), scope: .safe).isEmpty)
    }

    @Test("embedded applications require an explicit unlock and show their presence")
    func embeddedApplication() async throws {
        let fixture = try Fixture()
        try fixture.file("Game/Game.app/Contents/MacOS/Game")
        try fixture.app(fixture.shared.appendingPathComponent("Game/Game.app"), id: "com.vendor.game")
        let result = try await fixture.scan()
        let row = try #require(result.entries.first)
        #expect(row.isRemovalLocked)
        #expect(row.displayBytes > 0)
        #expect(row.reclaimableBytes == 0)
        #expect(row.safetyCaveat == "Contains Game.app")
        #expect(row.protectionReason == .userData)
        #expect(row.inventoryReason == nil)
        #expect(result.safeToRemoveBytes == 0)
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: []))
        #expect(CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
        #expect(CleanupService.alwaysMovesToTrash(row))
    }

    @Test("running embedded applications cannot be unlocked by identifier or path")
    func runningEmbeddedApplication() async throws {
        let fixture = try Fixture()
        try fixture.file("Game/Game.app/Contents/MacOS/Game")
        let app = fixture.shared.appendingPathComponent("Game/Game.app")
        try fixture.app(app, id: "com.vendor.game")
        let owner = FileEntry.RunningOwner(name: "Game", bundleIdentifier: "com.vendor.game", bundlePath: app.path)
        for context in [ScanContext(runningApplications: [owner]), ScanContext(runningApplicationPaths: [app.path])] {
            let result = try await fixture.scan(context)
            let row = try #require(result.entries.first)
            #expect(row.inventoryReason != nil)
            #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
        }
    }

    @Test("an embedded application does not permit removal of a media library")
    func embeddedApplicationWithLibrary() async throws {
        let fixture = try Fixture()
        try fixture.app(fixture.shared.appendingPathComponent("Family/Game.app"), id: "com.vendor.game")
        try fixture.file("Family/Photos.photoslibrary/database")
        let result = try await fixture.scan()
        let row = try #require(result.entries.first)
        #expect(row.inventoryReason != nil)
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
    }

    @Test("known vendor data stays locked for installed and running owners")
    func vendorOwners() async throws {
        let fixture = try Fixture()
        try fixture.file("Adobe/data")
        try fixture.app(fixture.apps.appendingPathComponent("Photoshop.app"), id: "com.adobe.Photoshop")
        let installed = try await fixture.scan()
        #expect(installed.entries.first?.safetyCaveat == "Used by Photoshop")
        #expect(installed.entries.first?.isRemovalLocked == true)
        try FileManager.default.removeItem(at: fixture.apps.appendingPathComponent("Photoshop.app"))
        let owner = FileEntry.RunningOwner(name: "Photoshop", bundleIdentifier: "com.adobe.Photoshop", bundlePath: "/External/Photoshop.app")
        let running = try await fixture.scan(ScanContext(runningApplications: [owner]))
        #expect(running.entries.first?.isRemovalLocked == true)
        #expect(running.entries.first?.safetyCaveat == "Used by Photoshop")
    }

    @Test("leftover routing preserves sibling folders and installed games")
    func leftoverPartition() async throws {
        let fixture = try Fixture()
        let download = try fixture.file("Epic Games/Fortnite/.egstore/chunk").deletingLastPathComponent().deletingLastPathComponent()
        try fixture.file("Epic Games/Personal/data")
        try fixture.file("Epic Games/MTGA/.egstore/manifest")
        try fixture.app(fixture.shared.appendingPathComponent("Epic Games/MTGA/MTGA.app"), id: "com.wizards.mtga")
        let shared = try await fixture.scan()
        #expect(shared.entries.count == 3)
        #expect(shared.entries.first { $0.url.lastPathComponent == "MTGA" }?.isRemovalLocked == true)
        #expect(shared.entries.first { $0.url.lastPathComponent == "Fortnite" }?.isRemovalLocked == true)
        let item = FileEntry(url: download, kind: .folder, allocatedBytes: 8192)
        let group = FileEntry(url: download, kind: .folder, allocatedBytes: 0,
                              removalAction: .orphanedApplication(bundleIdentifier: SharedApplicationData.epicLauncher), children: [item])
        let leftovers = ScanCategoryResult(categoryID: .applicationLeftovers, entries: [group])
        let results = ScanCoordinator.removingApplicationLeftoverOverlaps(from: [shared, leftovers])
        let remaining = try #require(results.first { $0.categoryID == .sharedData })
        #expect(Set(remaining.entries.map { $0.url.lastPathComponent }) == ["MTGA", "Personal"])
        #expect(remaining.totalBytes == remaining.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("known data cannot bypass leftover owner checks when the leftover category is off")
    func knownDataRemainsLocked() async throws {
        let fixture = try Fixture()
        try fixture.file("UnrealEngine/Launcher/SelfUpdateStaging/Install/Epic Games Launcher.app/Contents/MacOS/Epic")
        try fixture.app(fixture.shared.appendingPathComponent("UnrealEngine/Launcher/SelfUpdateStaging/Install/Epic Games Launcher.app"), id: SharedApplicationData.epicLauncher)
        let result = try await fixture.scan()
        let row = try #require(result.entries.first)
        #expect(row.inventoryReason?.contains("Application Leftovers") == true)
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
    }

    @Test("shared media libraries stay protected inside parent folders")
    func mediaLibraries() async throws {
        let fixture = try Fixture()
        try fixture.file("Family/Photos.photoslibrary/database")
        let result = try await fixture.scan()
        let row = try #require(result.entries.first)
        #expect(row.isRemovalLocked)
        #expect(row.safetyCaveat == "Used by Apple media library")
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
    }

    @Test("exclusions and symbolic links never become shared removal rows")
    func excludedPaths() async throws {
        let fixture = try Fixture()
        let secret = try fixture.file("Private/secret.keychain")
        try fixture.file("Other/data")
        try FileManager.default.createSymbolicLink(at: fixture.shared.appendingPathComponent("Link"), withDestinationURL: secret.deletingLastPathComponent())
        let result = try await fixture.scan(ScanContext(excludedPaths: [fixture.shared.appendingPathComponent("Other").path], excludedPatterns: ["*.keychain"]))
        #expect(result.entries.isEmpty)
        let excluded = try await fixture.scan(ScanContext(excludedPaths: [fixture.shared.path]))
        #expect(excluded.entries.isEmpty)
    }
}
