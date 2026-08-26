import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Storage Explorer")
struct StorageExplorerServiceTests {
    private final class Sandbox {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MacCleanerStorageExplorer-\(UUID().uuidString)")
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
        let name = "maccleaner-explorer-\(UUID().uuidString).bin"
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
}
