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

        #expect(library.protectionReason == .system)
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

        #expect(preferences.protectionReason == .system)
        #expect(!preferences.isRemovable)
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
}
