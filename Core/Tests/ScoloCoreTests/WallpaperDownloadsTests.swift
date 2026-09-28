import Foundation
import Testing
@testable import ScoloCore

@Suite("Downloaded Wallpapers")
struct WallpaperDownloadsTests {
    private let first = "11111111-1111-1111-1111-111111111111"
    private let second = "22222222-2222-2222-2222-222222222222"

    private final class Fixture {
        let home: URL
        var support: URL { home.appendingPathComponent("Library/Application Support") }
        var root: URL { home.appendingPathComponent(WallpaperDownloads.relativeRoot) }
        var settings: URL { root.deletingLastPathComponent().appendingPathComponent("Store/Index.plist") }
        var spacesSettings: URL { home.appendingPathComponent("Library/Preferences/com.apple.spaces.plist") }

        init() throws {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("scolo-wallpapers-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            home = path.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("videos"), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        func write(_ url: URL, data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func manifest(_ ids: [String], category: String = "landscape") throws {
            let assets: [[String: Any]] = ids.map {
                ["id": $0, "accessibilityLabel": "Scene \($0.prefix(1))", "categories": [category],
                 "subcategories": ["variants"], "url-4K-SDR-240FPS": "https://sylvan.apple.com/\($0).mov"]
            }
            try write(root.appendingPathComponent("manifest/entries.json"),
                      data: JSONSerialization.data(withJSONObject: ["assets": assets]))
        }

        @discardableResult
        func video(_ id: String) throws -> URL {
            let url = root.appendingPathComponent("videos/\(id).mov")
            try write(url, data: Data(repeating: 42, count: 8192))
            return url
        }

        func topology(_ monitors: [[String: Any]]) throws {
            try write(spacesSettings, data: PropertyListSerialization.data(fromPropertyList: [
                "SpacesDisplayConfiguration": ["Management Data": ["Monitors": monitors]]
            ], format: .binary, options: 0))
        }

        func index(selected: String? = nil, unknown: Bool = false, extra: String? = nil, shuffle: Bool = false) throws {
            func choice(_ id: String?) throws -> [String: Any] {
                let configuration: [String: Any] = id.map { ["assetID": $0] }
                    ?? ["type": "imageFile", "url": ["relative": "file:///Pictures/example.jpg"]]
                return ["Provider": unknown ? "future-provider" : (id == nil
                    ? "com.apple.wallpaper.choice.image" : "com.apple.wallpaper.choice.aerials"),
                    "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)]
            }
            let content: [String: Any] = ["Choices": [try choice(selected)],
                                          "Shuffle": shuffle ? ["Type": "afterDuration"] : "$null"]
            var index: [String: Any] = ["SystemDefault": ["Desktop": ["Content": content]],
                                       "Spaces": [:], "Displays": [:]]
            if let extra {
                index["Displays"] = ["second-display": ["Idle": ["Content": ["Choices": [try choice(extra)], "Shuffle": "$null"]]]]
            }
            try write(settings, data: PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0))
            try topology([["Display Identifier": "second-display", "Spaces": [["uuid": ""]]]])
        }

        func scan(context: ScanContext = ScanContext()) async throws -> ScanCategoryResult {
            try await SystemCachesScanner(cachesRoot: home.appendingPathComponent("Library/Caches"),
                                          logsRoot: home.appendingPathComponent("Library/Logs"),
                                          applicationSupportRoot: support).scan(context: context)
        }
    }


    @Test("Only existing Desktops and connected display overrides establish selected downloads")
    func historicalDesktops() async throws {
        let f = try Fixture()
        try f.manifest([first, second]); try f.video(first); try f.video(second)
        try f.index(selected: first)
        let bytes = try Data(contentsOf: f.settings)
        var index = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let aerial = try #require(index["SystemDefault"] as? [String: Any])
        try f.index()
        let imageBytes = try Data(contentsOf: f.settings)
        let imageIndex = try #require(PropertyListSerialization.propertyList(from: imageBytes, format: nil) as? [String: Any])
        let image = try #require(imageIndex["SystemDefault"] as? [String: Any])
        // An image overrides the old aerial default on the current Desktop.
        index["Spaces"] = [
            "": ["Default": image, "Displays": ["old-display": aerial]],
            "deleted-desktop": ["Default": aerial],
            "other-desktop": ["Default": aerial]
        ]
        index["Displays"] = ["old-display": aerial]
        try f.write(f.settings, data: PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0))
        try f.topology([
            ["Display Identifier": "second-display", "Spaces": [["uuid": ""]]],
            ["Display Identifier": "old-display", "Collapsed Space": ["uuid": "deleted-desktop"]]
        ])
        var result = try await f.scan()
        #expect(result.entries[0].children.allSatisfy { $0.regeneratesSafely })
        let entry = try #require(result.entries[0].children.first { $0.url.lastPathComponent == first + ".mov" })
        // An existing Desktop still needs protection when it is not the current Desktop.
        try f.topology([["Display Identifier": "second-display", "Spaces": [["uuid": ""], ["uuid": "other-desktop"]]]])
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == false)
        result = try await f.scan()
        #expect(result.entries[0].children.first { $0.url == entry.url }?.isRemovalLocked == true)
        // A connected display override also needs protection.
        try f.topology([["Display Identifier": "old-display", "Spaces": [["uuid": ""]]]])
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == false)
    }

    @Test("Missing Desktop information requires review without claiming historical selections are active")
    func missingTopology() async throws {
        let f = try Fixture()
        try f.manifest([first]); try f.video(first); try f.index(selected: first)
        try FileManager.default.removeItem(at: f.spacesSettings)
        let result = try await f.scan()
        let entry = try #require(result.entries.first?.children.first)
        #expect(!entry.isRemovalLocked)
        #expect(!entry.regeneratesSafely)
        #expect(entry.safeRemovalReviewReason != nil)
    }

    @Test("Wallpaper groups and downloads do not show filesystem dates as usage")
    func usagePresentation() async throws {
        let f = try Fixture()
        try f.manifest([first, second]); try f.index(selected: first)
        try f.video(first); try f.video(second)
        let result = try await f.scan()
        let group = try #require(result.entries.first)
        #expect(!FileEntryPresentation.showsLastOpened(for: group))
        #expect(group.children.allSatisfy { !FileEntryPresentation.showsLastOpened(for: $0) })
        #expect(result.tileRows(safeToRemove: true).allSatisfy { !FileEntryPresentation.showsLastOpened(for: $0) })
        #expect(FileEntryPresentation.showsLastOpened(for: FileEntry(url: f.home, kind: .folder, allocatedBytes: 0)))
    }

    @Test("Known unused downloads appear as safe children in the existing category")
    func unused() async throws {
        let f = try Fixture()
        try f.manifest([first, second]); try f.index(selected: first)
        try f.video(first); try f.video(second)
        let result = try await f.scan()
        let group = try #require(result.entries.first)
        #expect(result.categoryID == .systemCaches)
        #expect(group.displayName == "Downloaded Wallpapers")
        #expect(group.isRemovalLocked)
        #expect(group.children.count == 2)
        #expect(result.totalBytes == group.children.reduce(0) { $0 + $1.allocatedBytes })
        let safe = result.tileRows(safeToRemove: true)
        #expect(safe.count == 1)
        #expect(safe.first?.displayName == "Wallpaper · Scene 2")
        #expect(safe.first?.regeneratesSafely == true)
        let selected = try #require(group.children.first { $0.url.lastPathComponent == first + ".mov" })
        #expect(selected.isRemovalLocked)
        #expect(selected.wallpaperDownload?.permitsRemoval(of: selected.url) == false)
        #expect(CleanupService.alwaysMovesToTrash(try #require(safe.first)))
        #expect(result.safeToRemoveBytes + result.needsReviewBytes == result.totalBytes)
    }

    @Test("All displays, screen savers, and dynamic variants protect their selected downloads")
    func selections() async throws {
        let f = try Fixture()
        try f.manifest([first, second]); try f.index(selected: first, extra: second)
        try f.video(first); try f.video(second)
        #expect(try await f.scan().entries[0].children.allSatisfy(\.isRemovalLocked))
        try f.manifest([first, second], category: "dynamic-aerials")
        try f.index(selected: first)
        #expect(try await f.scan().entries[0].children.allSatisfy(\.isRemovalLocked))
        try f.manifest([first, second]); try f.index(selected: "landscape")
        #expect(try await f.scan().entries[0].children.allSatisfy(\.isRemovalLocked))
    }

    @Test("Unknown settings require review and are never selected as safe")
    func uncertainty() async throws {
        let f = try Fixture()
        try f.manifest([first]); try f.video(first); try f.index(unknown: true)
        var result = try await f.scan()
        let entry = try #require(result.entries.first?.children.first)
        #expect(entry.isRegenerable)
        #expect(!entry.regeneratesSafely)
        #expect(entry.safeRemovalReviewReason != nil)
        #expect(result.safeToRemoveBytes == 0)
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == true)
        try f.index(shuffle: true)
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == false)
        result = try await f.scan()
        #expect(result.safeToRemoveBytes == 0)
        try f.write(f.settings, data: Data("broken".utf8))
        #expect(try await f.scan().safeToRemoveBytes == 0)
        try FileManager.default.removeItem(at: f.settings)
        #expect(try await f.scan().safeToRemoveBytes == 0)
    }

    @Test("Usage timestamps do not change the reviewed wallpaper selection")
    func timestampChanges() async throws {
        let f = try Fixture()
        try f.manifest([first]); try f.video(first); try f.index(unknown: true)
        let result = try await f.scan()
        let entry = try #require(result.entries.first?.children.first)
        let bytes = try Data(contentsOf: f.settings)
        var index = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var defaults = try #require(index["SystemDefault"] as? [String: Any])
        defaults["LastUse"] = Date()
        index["SystemDefault"] = defaults
        try f.write(f.settings, data: PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0))
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == true)
    }

    @Test("Missing manifest entries, unexpected files, and symbolic links cannot become safe downloads")
    func boundaries() async throws {
        let f = try Fixture()
        try f.manifest([first]); try f.index()
        try f.video(first); try f.video(second)
        try f.write(f.root.appendingPathComponent("videos/settings.plist"), data: Data(repeating: 1, count: 4096))
        let linked = f.root.appendingPathComponent("videos/33333333-3333-3333-3333-333333333333.mov")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.root.appendingPathComponent("videos/\(first).mov"))
        let result = try await f.scan()
        #expect(result.entries[0].children.count == 2)
        #expect(result.entries[0].children.first { $0.url.lastPathComponent == second + ".mov" }?.isRemovalLocked == true)
        let excluded = try await f.scan(context: ScanContext(excludedPaths: [f.root.path]))
        #expect(excluded.entries.isEmpty)
        try f.write(f.root.appendingPathComponent("manifest/entries.json"), data: Data("broken".utf8))
        #expect(try await f.scan().entries[0].children.allSatisfy(\.isRemovalLocked))
    }

    @Test("Removal rejects stale selection and file identity")
    func recheck() async throws {
        let f = try Fixture()
        try f.manifest([first]); try f.index(); let url = try f.video(first)
        let result = try await f.scan()
        let entry = try #require(result.entries.first?.children.first)
        #expect(entry.wallpaperDownload?.permitsRemoval(of: entry.url) == true)
        try f.index(selected: first)
        let outcome = try await CleanupService().remove(entries: [entry], trashFirst: false, keepReceipt: false)
        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [entry.url.path])
        #expect(FileManager.default.fileExists(atPath: url.path))
        try f.index()
        let replacement = f.root.appendingPathComponent("replacement")
        try f.write(replacement, data: Data(repeating: 12, count: 8192))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        #expect(entry.wallpaperDownload?.permitsRemoval(of: url) == false)
    }

    @Test("Registry classification preserves wallpaper settings and applies live selection rules")
    func registry() throws {
        let f = try Fixture()
        try f.manifest([first]); try f.index(selected: first); let url = try f.video(first)
        let registry = StorageRuleRegistry.standard(home: f.home)
        let video = registry.classify(FileEntry(url: url, kind: .file, allocatedBytes: 8192), home: f.home, context: ScanContext())
        #expect(video.isRemovalLocked)
        #expect(video.wallpaperDownload != nil)
        let folder = registry.classify(FileEntry(url: f.root, kind: .folder, allocatedBytes: 8192), home: f.home, context: ScanContext())
        #expect(folder.isRemovalLocked)
        #expect(!folder.regeneratesSafely)
    }
}
