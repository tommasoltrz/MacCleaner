import Foundation
import Testing
import Synchronization
@testable import ScoloCore

@Suite("Storage Explorer")
struct StorageExplorerServiceTests {
    private final class Sandbox {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ScoloStorageExplorer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, bytes: Int = 128) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
    }

    @Test("one traversal supplies nested folders and partial results")
    func nestedAndPartialResults() async throws {
        let box = try Sandbox()
        _ = try box.write("Project/Build/output.bin", bytes: 8_192)
        _ = try box.write("Project/source.swift", bytes: 128)
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent("Project/Empty"), withIntermediateDirectories: true)
        _ = try box.write("Project/secret.keychain", bytes: 128)
        let updates = Mutex<[StorageExplorerScanUpdate]>([])
        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root, excludedPatterns: ["*.keychain"],
            onUpdate: { update in updates.withLock { $0.append(update) } }
        )
        let events = updates.withLock { $0 }
        guard case .partial(let first) = events.first else {
            Issue.record("The scan must publish partial content before completion.")
            return
        }
        #expect(first.isPartial)
        #expect(first.items.map(\.name) == ["Project"])
        #expect(!snapshot.isPartial)
        let retained = events.flatMap { event -> [StorageExplorerSnapshot] in
            if case .retained(let snapshots) = event { return snapshots }
            return []
        }
        let project = try #require(retained.first { $0.directory.lastPathComponent == "Project" })
        #expect(Set(project.items.map(\.name)) == ["Build", "Empty", "source.swift", "secret.keychain"])
        #expect(project.allocatedBytes == snapshot.allocatedBytes)
        #expect(project.fileCount == 3)
        #expect(project.items.first { $0.name == "secret.keychain" }?.protectionReason == .protectedContents)
        let build = try #require(retained.first { $0.directory.lastPathComponent == "Build" })
        #expect(build.allocatedBytes == project.items.first { $0.name == "Build" }?.allocatedBytes)
        #expect(build.fileCount == 1)
        #expect(retained.first { $0.directory.lastPathComponent == "Empty" }?.items.isEmpty == true)
    }

    @Test("retained folders preserve shared-file accounting")
    func retainedHardLinks() async throws {
        let box = try Sandbox()
        let original = try box.write("Alpha/shared.bin", bytes: 8_192)
        let link = box.root.appendingPathComponent("Beta/shared.bin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: link)
        let retained = Mutex<[StorageExplorerSnapshot]>([])
        let snapshot = try await StorageExplorerService(home: box.root).scan(directory: box.root, onUpdate: { event in
            if case .retained(let snapshots) = event { retained.withLock { $0 = snapshots } }
        })
        for nested in retained.withLock({ $0 }) {
            let parentItem = try #require(snapshot.items.first { $0.url == nested.directory })
            #expect(nested.allocatedBytes == parentItem.allocatedBytes)
            #expect(nested.fileCount == parentItem.fileCount)
        }
        #expect(snapshot.fileCount == 1)
    }

    @Test("partial sizes arrive before the final result and retention stays bounded")
    func incrementalSizes() async throws {
        let box = try Sandbox()
        for folder in 0..<140 {
            for file in 0..<5 { _ = try box.write("folder-\(folder)/file-\(file)") }
        }
        let updates = Mutex<[StorageExplorerScanUpdate]>([])
        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root, onUpdate: { event in updates.withLock { $0.append(event) } }
        )
        let events = updates.withLock { $0 }
        let partials = events.compactMap { event -> StorageExplorerSnapshot? in
            if case .partial(let snapshot) = event { return snapshot }
            return nil
        }
        let retained = events.flatMap { event -> [StorageExplorerSnapshot] in
            if case .retained(let snapshots) = event { return snapshots }
            return []
        }
        #expect(partials.count >= 2)
        #expect(partials.first?.allocatedBytes == 0)
        #expect(partials.dropFirst().contains { $0.allocatedBytes > 0 })
        #expect(partials.allSatisfy { $0.isPartial && $0.allocatedBytes <= snapshot.allocatedBytes })
        #expect(snapshot.fileCount == 700)
        #expect(retained.count == 128)
        #expect(retained.allSatisfy { $0.fileCount == 5 })
    }

    @Test("one level contains each immediate child once")
    func immediateChildren() async throws {
        let box = try Sandbox()
        _ = try box.write("Alpha/one.bin")
        _ = try box.write("Beta/two.bin")
        _ = try box.write("loose.bin")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )

        #expect(Set(snapshot.items.map(\.name)) == ["Alpha", "Beta", "loose.bin"])
        #expect(snapshot.allocatedBytes == snapshot.items.reduce(0) { $0 + $1.allocatedBytes })
        #expect(snapshot.fileCount == 3)
        #expect(snapshot.items.first(where: { $0.name == "Alpha" })?.fileCount == 1)
    }

    @Test("hard links do not make sibling totals exceed the parent")
    func hardLinksAcrossChildren() async throws {
        let box = try Sandbox()
        let original = try box.write("Alpha/shared.bin", bytes: 8_192)
        let link = box.root.appendingPathComponent("Beta/shared.bin")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: original, to: link)

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )
        let whole = try await AllocatedSizeMeasurer().measure(box.root)

        #expect(snapshot.allocatedBytes == whole.allocatedBytes)
        #expect(snapshot.fileCount == 1)
    }

    @Test("an exclusion protects its parent row")
    func exclusionProtectsAncestor() async throws {
        let box = try Sandbox()
        let excluded = try box.write("Project/Private/secret.bin")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root,
            excludedPaths: [excluded.deletingLastPathComponent().path]
        )
        let project = try #require(snapshot.items.first { $0.name == "Project" })

        #expect(project.protectionReason == .excluded)
        #expect(!project.isRemovable)
    }

    @Test("a protected pattern locks the containing row")
    func patternProtectsAncestor() async throws {
        let box = try Sandbox()
        _ = try box.write("Project/Secrets.keychain-db")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root,
            excludedPatterns: ["*.keychain-db"]
        )
        let project = try #require(snapshot.items.first { $0.name == "Project" })

        #expect(project.protectionReason == .protectedContents)
    }

    @Test("cloud state distinguishes local and cloud-only content")
    func cloudStatePolicy() {
        #expect(StorageExplorerService.cloudState(
            isUbiquitousItem: false,
            isDownloaded: false,
            containsCloudOnlyItems: false
        ) == .none)
        #expect(StorageExplorerService.cloudState(
            isUbiquitousItem: true,
            isDownloaded: true,
            containsCloudOnlyItems: false
        ) == .downloaded)
        #expect(StorageExplorerService.cloudState(
            isUbiquitousItem: true,
            isDownloaded: false,
            containsCloudOnlyItems: false
        ) == .cloudOnly)
        #expect(StorageExplorerService.cloudState(
            isUbiquitousItem: false,
            isDownloaded: false,
            containsCloudOnlyItems: true
        ) == .containsCloudOnlyItems)
    }

    @Test("cloud-only state survives measurement addition")
    func cloudStateCombines() {
        let local = SizeMeasurement(allocatedBytes: 10, fileCount: 1)
        let cloud = SizeMeasurement(containsCloudOnlyItem: true)

        #expect((local + cloud).containsCloudOnlyItem)
    }

    @Test("the home Library folder is system managed")
    func protectsHomeLibrary() async throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(
            at: box.root.appendingPathComponent("Library"),
            withIntermediateDirectories: true
        )

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )
        let library = try #require(snapshot.items.first { $0.name == "Library" })

        #expect(library.protectionReason == .library)
    }

    @Test("items inside the home Library stay protected")
    func protectsHomeLibraryContents() async throws {
        let box = try Sandbox()
        let library = box.root.appendingPathComponent("Library", isDirectory: true)
        _ = try box.write("Library/Preferences/example.plist")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: library
        )
        let preferences = try #require(snapshot.items.first { $0.name == "Preferences" })

        #expect(preferences.protectionReason == .library)
        #expect(!preferences.isRemovable)
    }

    @Test("iCloud Drive contents are not locked as Library data")
    func allowsUserICloudDocuments() async throws {
        let box = try Sandbox()
        let cloudDocs = box.root
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        _ = try box.write("Library/Mobile Documents/com~apple~CloudDocs/document.pdf")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: cloudDocs
        )
        let document = try #require(snapshot.items.first { $0.name == "document.pdf" })

        #expect(document.protectionReason == nil)
        #expect(document.isRemovable)
    }

    @Test("a missing root reports that it is unavailable")
    func missingRoot() async throws {
        let box = try Sandbox()
        let missing = box.root.appendingPathComponent("Missing")

        await #expect(throws: StorageExplorerError.unavailable(missing.path)) {
            try await StorageExplorerService(home: box.root).scan(directory: missing)
        }
    }

    @Test("removal refuses a replacement at the reviewed path")
    func removalChecksIdentity() async throws {
        let box = try Sandbox()
        let file = try box.write("reviewed.bin")
        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )
        let reviewed = try #require(snapshot.items.first { $0.name == file.lastPathComponent })
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 9, count: 128).write(to: file)

        let outcome = try await StorageExplorerRemovalService().remove(
            [reviewed],
            from: box.root,
            keepReceipt: false
        )

        #expect(outcome.failed == [reviewed.url.path])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("selection review refuses a replacement at the same path")
    func selectionReviewChecksIdentity() async throws {
        let box = try Sandbox()
        let file = try box.write("reviewed.bin")
        let service = StorageExplorerService(home: box.root)
        let snapshot = try await service.scan(directory: box.root)
        let reviewed = try #require(snapshot.items.first { $0.name == file.lastPathComponent })
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 9, count: 128).write(to: file)

        let review = try await service.reviewSelection([reviewed], in: box.root)

        #expect(!review.isReady)
        #expect(review.changedPaths == [reviewed.url.path])
        #expect(review.items.isEmpty)
    }

    @Test("selection review refreshes a changed size for the same item")
    func selectionReviewRefreshesSize() async throws {
        let box = try Sandbox()
        let file = try box.write("growing.bin", bytes: 128)
        let service = StorageExplorerService(home: box.root)
        let snapshot = try await service.scan(directory: box.root)
        let reviewed = try #require(snapshot.items.first { $0.name == file.lastPathComponent })
        try Data(repeating: 9, count: 2_000_000).write(to: file)

        let review = try await service.reviewSelection([reviewed], in: box.root)
        let refreshed = try #require(review.items.first)

        #expect(review.isReady)
        #expect(refreshed.identity == reviewed.identity)
        #expect(refreshed.allocatedBytes > reviewed.allocatedBytes)
    }

    @Test("selection review stops when an item becomes protected")
    func selectionReviewChecksProtection() async throws {
        let box = try Sandbox()
        let file = try box.write("protected.bin")
        let service = StorageExplorerService(home: box.root)
        let snapshot = try await service.scan(directory: box.root)
        let reviewed = try #require(snapshot.items.first { $0.name == file.lastPathComponent })

        let review = try await service.reviewSelection(
            [reviewed],
            in: box.root,
            excludedPaths: [file.path]
        )

        #expect(!review.isReady)
        #expect(review.protectedPaths == [reviewed.url.path])
        #expect(review.items.isEmpty)
    }

    @Test("removal accepts only a reviewed direct child")
    func removalChecksParent() async throws {
        let box = try Sandbox()
        let nested = try box.write("Folder/nested.bin")
        let folder = nested.deletingLastPathComponent()
        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: folder
        )
        let reviewed = try #require(snapshot.items.first { $0.name == nested.lastPathComponent })

        let outcome = try await StorageExplorerRemovalService().remove(
            [reviewed],
            from: box.root,
            keepReceipt: false
        )

        #expect(outcome.failed == [reviewed.url.path])
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("a reviewed file moves to the Trash")
    func removalMovesToTrash() async throws {
        let box = try Sandbox()
        let name = "scolo-explorer-\(UUID().uuidString).bin"
        let file = try box.write(name)
        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )
        let reviewed = try #require(snapshot.items.first { $0.name == file.lastPathComponent })
        let trashed = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: trashed) }

        let outcome = try await StorageExplorerRemovalService().remove(
            [reviewed],
            from: box.root,
            keepReceipt: false
        )

        #expect(outcome.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test("a document package is a file; a media library and the Trash are locked")
    func packagesAndLibraries() async throws {
        let box = try Sandbox()
        _ = try box.write("Notes.rtfd/TXT.rtf")
        _ = try box.write("Photos Library.photoslibrary/database/Photos.sqlite")
        _ = try box.write(".Trash/old.bin")

        let snapshot = try await StorageExplorerService(home: box.root).scan(
            directory: box.root
        )
        let notes = try #require(snapshot.items.first { $0.name.hasPrefix("Notes") })
        let photos = try #require(snapshot.items.first { $0.name.hasPrefix("Photos") })
        let trash = try #require(snapshot.items.first { $0.url.lastPathComponent == ".Trash" })

        #expect(notes.protectionReason == nil)
        #expect(notes.isRemovable)
        #expect(photos.protectionReason == .mediaLibrary)
        #expect(trash.protectionReason == .trash)
    }

    @Test("Trash stays protected outside the configured home", arguments: [
        ".nofollow/Users/person/.Trash",
        "System/Volumes/Data/Users/person/.Trash",
        "Volumes/External/.Trashes/501",
        "Library/Mobile Documents/.Trash",
        ".nofollow/Users/person/.Trash/nested"
    ])
    func protectsAlternateTrashPaths(_ path: String) async throws {
        let box = try Sandbox()
        let file = try box.write(path + "/old.bin")
        let trash = file.deletingLastPathComponent()
        let service = StorageExplorerService(home: box.root.appendingPathComponent("Home"))
        let snapshot = try await service.scan(directory: trash.deletingLastPathComponent())
        let item = try #require(snapshot.items.first { $0.url.lastPathComponent == trash.lastPathComponent })

        #expect(item.protectionReason == .trash)
        #expect(!item.isRemovable)
        let contents = try await service.scan(directory: trash)
        #expect(contents.items.allSatisfy { $0.protectionReason == .trash && !$0.isRemovable })

        var staleItem = item
        staleItem.protectionReason = nil
        let review = try await service.reviewSelection([staleItem], in: snapshot.directory)
        #expect(!review.isReady)
        #expect(review.protectedPaths == [item.url.path])

        let outcome = try await StorageExplorerRemovalService().remove(
            [staleItem], from: snapshot.directory, keepReceipt: false
        )
        #expect(outcome.failed == [item.url.path])
        #expect(outcome.removedCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a symbolic link cannot bypass Trash protection")
    func protectsTrashLink() async throws {
        let box = try Sandbox()
        let file = try box.write(".Trash/old.bin")
        let link = box.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.deletingLastPathComponent())
        #expect(StorageExplorerService.isTrashLocation(link))
        #expect(StorageExplorerService.isTrashLocation(link.appendingPathComponent("old.bin")))
    }

    @Test("an ordinary folder named Trash is removable")
    func ordinaryTrashName() async throws {
        let box = try Sandbox()
        _ = try box.write("Trash/document.bin")
        _ = try box.write(".Trash-backup/document.bin")
        let snapshot = try await StorageExplorerService(home: box.root).scan(directory: box.root)
        #expect(snapshot.items.count == 2)
        #expect(snapshot.items.allSatisfy { $0.isRemovable })
    }
}
