import Foundation
import Testing
@testable import ScoloCore

@Suite("Photos library storage")
struct PhotosLibraryStorageTests {
    @Test("Library resources remain protected when Photos is closed or running")
    func protectedResources() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scolo-photos-storage-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rules = StorageRuleRegistry.photosLibraryResourceRules
        for rule in rules {
            let folder = home.appendingPathComponent(rule.path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("image"))
        }
        let owner = FileEntry.RunningOwner(
            name: "Photos", bundleIdentifier: "com.apple.Photos",
            bundlePath: "/System/Applications/Photos.app"
        )
        for running in [false, true] {
            let context = ScanContext(runningApplications: running ? [owner] : [])
            let result = try await HiddenDataScanner(home: home).scan(context: context)
            #expect(result.entries.count == 2)
            #expect(result.safeToRemoveBytes == 0)
            for entry in result.entries {
                let rule = try #require(entry.storageRule)
                #expect(rules.contains(rule))
                #expect(entry.displayName == rule.title)
                #expect(entry.contentDescription == rule.summary)
                #expect(!entry.isRegenerable)
                #expect(entry.isRemovalLocked)
                #expect(entry.inventoryReason == rule.removalEffect)
                #expect(entry.inUseBy == (running ? owner : nil))
                #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
                #expect(StorageRuleRegistry.standard(home: home).resolve(entry.url, home: home) == .known(rule))
            }
        }
    }

    @Test("Photos resource rules do not classify originals or unrelated folders as caches")
    func boundaries() {
        let home = URL(fileURLWithPath: "/photos-test-home")
        let registry = StorageRuleRegistry.standard(home: home)
        for path in [
            "Pictures/Photos Library.photoslibrary/originals",
            "Pictures/Photos Library.photoslibrary/database",
            "Documents/resources/derivatives"
        ] {
            #expect(registry.resolve(home.appendingPathComponent(path), home: home) == .unknown)
        }
    }
}
