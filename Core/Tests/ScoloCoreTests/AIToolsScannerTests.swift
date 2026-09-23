import Foundation
import Testing
@testable import ScoloCore

@Suite("AI tool storage")
struct AIToolsScannerTests {
    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("scolo-ai-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: home) }
        @discardableResult
        func file(_ path: String, bytes: Int = 8192) throws -> URL {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: bytes).write(to: url)
            return url
        }
        func scan(_ context: ScanContext = ScanContext()) async throws -> ScanCategoryResult {
            try await AIToolsScanner(home: home).scan(context: context)
        }
    }

    @Test("Downloaded runtimes belong to AI Tools and retain their owner when closed")
    func downloadedRuntimeOwnership() async throws {
        let fixture = try Fixture()
        try fixture.file(".cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node")
        let owner = FileEntry.RunningOwner(name: "Codex", bundleIdentifier: "com.openai.codex", bundlePath: "/Applications/Codex.app")
        let running = try await fixture.scan(ScanContext(runningApplications: [owner]))
        let active = try #require(running.entries.first)
        #expect(active.displayName == "Codex · Downloaded runtime")
        #expect(active.isRegenerable)
        #expect(active.inUseBy == owner)
        #expect(active.ownerRules == [.bundleIdentifier("com.openai.codex")])
        #expect(running.safeToRemoveBytes == 0)
        let stopped = try await fixture.scan()
        let cache = try #require(stopped.entries.first)
        #expect(cache.inUseBy == nil)
        #expect(stopped.safeToRemoveBytes == stopped.totalBytes)
        #expect(ScanContext(runningApplications: [owner]).runningOwner(for: cache) == owner)
        let generic = try await SystemCachesScanner(
            cachesRoot: fixture.home.appendingPathComponent("Library/Caches"),
            logsRoot: fixture.home.appendingPathComponent("Library/Logs"),
            dotCacheRoot: fixture.home.appendingPathComponent(".cache")
        ).scan(context: ScanContext())
        #expect(generic.entries.isEmpty)
    }

    @Test("Runtime exclusions and symbolic links cannot bypass AI cache rules")
    func runtimeExclusions() async throws {
        let fixture = try Fixture()
        let file = try fixture.file(".cache/codex-runtimes/runtime/private.keychain")
        #expect(try await fixture.scan(ScanContext(excludedPatterns: ["*.keychain"])).entries.isEmpty)
        #expect(try await fixture.scan(ScanContext(excludedPaths: [file.path])).entries.isEmpty)
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.removeItem(at: root)
        let outside = try fixture.file("outside/tools").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(try await fixture.scan().entries.isEmpty)
    }

    @Test("session and worktree storage requires an exact user-data override")
    func userDataLocks() async throws {
        let fixture = try Fixture()
        try fixture.file(".codex/sessions/2026/09/session.jsonl")
        try fixture.file(".claude/projects/project/session.jsonl")
        try fixture.file(".cursor/worktrees/project/branch/unfinished.swift")
        try fixture.file(".codex/auth.json")
        try fixture.file(".claude/settings.json")
        let result = try await fixture.scan()
        #expect(result.entries.count == 3)
        #expect(result.totalBytes > 0)
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.needsReviewBytes == result.totalBytes)
        let rows = result.entries + result.entries.flatMap(\.children)
        for row in rows {
            #expect(row.isRemovalLocked)
            #expect(row.reclaimableBytes == 0)
            #expect(row.inventoryReason == nil)
            #expect(row.protectionReason == .userData)
            #expect(row.userDataRemovalWarning != nil)
            #expect(row.displayBytes > 0)
            #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: []))
            #expect(CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
            #expect(CleanupService.alwaysMovesToTrash(row))
        }
        #expect(rows.allSatisfy { $0.lastOpened != nil })
        let outcome = try await CleanupService(log: RemovalLog(directory: fixture.home.appendingPathComponent("receipts")))
            .remove(entries: rows, trashFirst: true, keepReceipt: false, userDataRemovalOverrides: [])
        #expect(outcome.removedCount == 0)
        #expect(outcome.failed.count == rows.count)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/sessions/2026/09/session.jsonl").path))
    }

    @Test("a protected worktree child cannot be removed through its parent")
    func protectedWorktreeContents() async throws {
        let fixture = try Fixture()
        try fixture.file(".cursor/worktrees/private/secret.keychain-db")
        try fixture.file(".cursor/worktrees/review/unfinished.swift")
        let result = try await fixture.scan(ScanContext(excludedPatterns: ["*.keychain-db"]))
        let parent = try #require(result.entries.first)
        #expect(parent.inventoryReason != nil)
        #expect(!CleanupService.removalAllowed(parent, userDataRemovalOverrides: [parent.id]))
        #expect(parent.children.count == 1)
        let child = try #require(parent.children.first)
        #expect(child.url.lastPathComponent == "review")
        #expect(CleanupService.removalAllowed(child, userDataRemovalOverrides: [child.id]))
        #expect(result.safeToRemoveBytes == 0)
    }

    @Test("verified desktop caches exclude profiles and become safe after the owner quits")
    func cacheOwnership() async throws {
        let fixture = try Fixture()
        try fixture.file("Library/Application Support/Cursor/Code Cache/data")
        try fixture.file("Library/Application Support/Cursor/Service Worker/CacheStorage/data")
        try fixture.file("Library/Application Support/Cursor/Shared Dictionary/data")
        try fixture.file("Library/Application Support/Cursor/User/workspaceStorage/project/state.vscdb")
        try fixture.file(".claude/cache/unknown")
        let owner = FileEntry.RunningOwner(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", bundlePath: "/Applications/Cursor.app")
        let running = try await fixture.scan(ScanContext(runningApplications: [owner]))
        #expect(running.entries.filter(\.isRegenerable).count == 1)
        #expect(running.safeToRemoveBytes == 0)
        #expect(running.entries.first(where: \.isRegenerable)?.inUseBy == owner)
        let pathsOnly = try await fixture.scan(ScanContext(runningApplicationPaths: [owner.bundlePath]))
        #expect(pathsOnly.safeToRemoveBytes == 0)
        let stopped = try await fixture.scan()
        #expect(stopped.safeToRemoveBytes > 0)
        #expect(stopped.tileRows(safeToRemove: true).allSatisfy { $0.url.path.contains("Code Cache") })
        #expect(stopped.entries.count == 2)
    }

    @Test("exclusions, protected files, and symbolic links prevent cache cleanup")
    func exclusionsAndLinks() async throws {
        let fixture = try Fixture()
        let protected = try fixture.file("Library/Application Support/Cursor/Code Cache/secret.keychain")
        try fixture.file(".codex/sessions/year/private.jsonl")
        let outside = try fixture.file("other/session.jsonl").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent(".codex/archived_sessions"), withDestinationURL: outside)
        let result = try await fixture.scan(ScanContext(
            excludedPaths: [fixture.home.appendingPathComponent(".codex/sessions").path], excludedPatterns: ["*.keychain"]
        ))
        #expect(result.entries.isEmpty)
        try FileManager.default.removeItem(at: protected.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: protected.deletingLastPathComponent(), withDestinationURL: outside)
        #expect(try await fixture.scan().entries.allSatisfy { !$0.isRegenerable })
    }

    @Test("Claude project worktrees are found without reading Git or conversation contents")
    func projectWorktrees() async throws {
        let fixture = try Fixture()
        try fixture.file("Documents/Example/.claude/worktrees/topic/unfinished.txt")
        try fixture.file("Documents/Example/node_modules/dependency/.claude/worktrees/topic/file")
        let result = try await fixture.scan()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.displayName == "Claude worktrees · Example")
        #expect(result.entries.first?.children.count == 1)
        #expect(result.entries.first?.isRemovalLocked == true)
    }

    @Test("AI storage removes duplicate cache rows and generic parents that bypass its locks")
    func categoryOwnership() {
        let cache = FileEntry(url: URL(fileURLWithPath: "/home/Library/Application Support/Cursor/Code Cache"), kind: .cache, allocatedBytes: 100, isRegenerable: true)
        let inventory = FileEntry(url: URL(fileURLWithPath: "/home/.codex/sessions"), kind: .folder, allocatedBytes: 300, protectionReason: .userData, userDataRemovalWarning: "Saved sessions.")
        let bundle = FileEntry(url: URL(fileURLWithPath: "/Applications/Cursor.app"), kind: .appBundle, allocatedBytes: 200, children: [cache])
        let generic = FileEntry(url: URL(fileURLWithPath: "/home/.codex"), kind: .folder, allocatedBytes: 500)
        let results = [
            ScanCategoryResult(categoryID: .applications, entries: [bundle]),
            ScanCategoryResult(categoryID: .systemCaches, entries: [cache]),
            ScanCategoryResult(categoryID: .hiddenSystemData, entries: [generic]),
            ScanCategoryResult(categoryID: .aiTools, entries: [cache, inventory])
        ]
        let reconciled = ScanCoordinator.removingAIToolOverlaps(from: results)
        #expect(reconciled.first { $0.categoryID == .applications }?.entries.first?.children.isEmpty == true)
        #expect(reconciled.first { $0.categoryID == .systemCaches }?.entries.isEmpty == true)
        #expect(reconciled.first { $0.categoryID == .hiddenSystemData }?.entries.isEmpty == true)
        #expect(reconciled.reduce(0) { $0 + $1.safeToRemoveBytes } == 100)
        let withoutAI = Array(results.dropLast())
        #expect(ScanCoordinator.removingAIToolOverlaps(from: withoutAI) == withoutAI)
    }

    @Test("generic hidden scanning never offers an entire AI session store")
    func hiddenScannerOwnership() async throws {
        let fixture = try Fixture()
        try fixture.file(".codex/sessions/history.jsonl", bytes: 6 * 1024 * 1024)
        try fixture.file(".claude/projects/project/history.jsonl", bytes: 6 * 1024 * 1024)
        let result = try await HiddenDataScanner(home: fixture.home).scan(context: ScanContext())
        #expect(!result.entries.contains { $0.url.path.contains("/.codex") || $0.url.path.contains("/.claude") })
    }
}
