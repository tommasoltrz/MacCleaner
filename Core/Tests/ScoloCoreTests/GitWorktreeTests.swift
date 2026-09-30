import Foundation
import Testing
@testable import ScoloCore

@Suite("Git worktrees")
struct GitWorktreeTests {
    private final class Sandbox {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("scolo-worktrees-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func file(_ path: String, text: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func repository() throws -> URL {
            let repo = home.appendingPathComponent("Documents/Project", isDirectory: true)
            try file("Documents/Project/source.txt", text: String(repeating: "source\n", count: 200_000))
            try git(["init", repo.path])
            try git(["-C", repo.path, "add", "source.txt"])
            try git(["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Test"])
            return repo
        }

        func worktree(_ path: String, repository: URL) throws -> URL {
            let url = home.appendingPathComponent(path, isDirectory: true)
            try git(["-C", repository.path, "worktree", "add", "--detach", url.path])
            return url
        }
    }

    @Test("Project and AI folders show real worktrees without counting bytes twice")
    func scannerIntegration() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let projectTree = try sandbox.worktree("Documents/Project/.claude/worktrees/task", repository: repo)
        let codexTree = try sandbox.worktree(".codex/worktrees/abcd/Project", repository: repo)
        let claudeTree = try sandbox.worktree(".claude/worktrees/task", repository: repo)
        _ = try sandbox.worktree("Projects/task", repository: repo)
        try sandbox.file("Documents/Project/.claude/worktrees/task/.build/workspace-state.json", text: "{}")
        let context = ScanContext()
        let documents = try await DocumentsFilesScanner(home: sandbox.home).scan(context: context)
        let project = try #require(documents.entries.first { $0.url.path.hasSuffix("/Documents/Project") })
        let child = try #require(project.children.first { $0.url.path.hasSuffix("/Documents/Project/.claude/worktrees/task") })
        #expect(child.parentDisplay.contains("Git worktree"))
        #expect(!child.regeneratesSafely)
        #expect(child.safetyCaveat != nil)
        #expect(child.gitWorktreeStatus == .uncommittedChanges)
        let fullSize = try await context.measurer.measure(repo)
        #expect(project.displayBytes == fullSize.allocatedBytes)
        #expect(BuildOutputDetector.roots(under: projectTree).isEmpty)
        let standalone = try #require(documents.entries.first { $0.url.path.hasSuffix("/Projects/task") })
        #expect(standalone.parentDisplay.contains("Git worktree"))
        #expect(!standalone.isRegenerable)
        #expect(standalone.gitWorktreeStatus == .clean)
        #expect(standalone.gitWorktreePushStatus == .unknown)

        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        for tree in [codexTree, claudeTree] {
            let parent = try #require(hidden.entries.first { $0.children.contains { $0.url.path.hasSuffix(String(tree.path.dropFirst(sandbox.home.path.count))) } })
            let measurement = try await context.measurer.measure(parent.url)
            #expect(parent.displayBytes == measurement.allocatedBytes)
            #expect(parent.children.allSatisfy { !$0.regeneratesSafely })
        }
        #expect(hidden.totalBytes == hidden.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("Git status detects untracked, unstaged, staged, and deleted files")
    func worktreeStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        #expect(try await GitWorktreeDetector.status(of: tree) == .clean)

        try sandbox.file("Worktrees/task/new.swift", text: "// Test file\n")
        #expect(try await GitWorktreeDetector.status(of: tree) == .uncommittedChanges)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("new.swift"))
        #expect(try await GitWorktreeDetector.status(of: tree) == .clean)

        try sandbox.file("Worktrees/task/source.txt", text: "Changed source\n")
        #expect(try await GitWorktreeDetector.status(of: tree) == .uncommittedChanges)
        try sandbox.git(["-C", tree.path, "add", "source.txt"])
        #expect(try await GitWorktreeDetector.status(of: tree) == .uncommittedChanges)
        try sandbox.git(["-C", tree.path, "restore", "--staged", "--worktree", "source.txt"])
        #expect(try await GitWorktreeDetector.status(of: tree) == .clean)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("source.txt"))
        #expect(try await GitWorktreeDetector.status(of: tree) == .uncommittedChanges)
    }

    @Test("Ignored files do not produce a changes badge, and failed checks remain unknown")
    func ignoredAndUnavailableStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        try sandbox.file("Documents/Project/.git/info/exclude", text: "ignored-demo.bin\n")
        try sandbox.file("Worktrees/task/ignored-demo.bin", text: "Test data")
        #expect(try await GitWorktreeDetector.status(of: tree) == .clean)
        try sandbox.file("Stale/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        #expect(try await GitWorktreeDetector.status(of: sandbox.home.appendingPathComponent("Stale")) == .unavailable)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitWorktreeDetector.status(of: tree)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled status check completed")
        } catch is CancellationError {
        }
    }

    @Test("Push checks handle detached worktrees and the configured upstream")
    func unpushedCommits() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unknown)
        try sandbox.git(["-C", repo.path, "remote", "add", "origin", sandbox.home.appendingPathComponent("remote.git").path])
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .noUnpushedCommits)

        try sandbox.file("Worktrees/task/source.txt", text: "Committed change\n")
        try sandbox.git(["-C", tree.path, "add", "source.txt"])
        try sandbox.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Local change"])
        #expect(try await GitWorktreeDetector.status(of: tree) == .clean)
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unpushedCommits(1))
        try sandbox.file("Worktrees/task/untracked.swift", text: "// Local changes\n")
        #expect(try await GitWorktreeDetector.status(of: tree) == .uncommittedChanges)
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unpushedCommits(1))

        try sandbox.git(["-C", tree.path, "update-ref", "refs/remotes/origin/other", "HEAD"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .noUnpushedCommits)
        try sandbox.git(["-C", tree.path, "switch", "-c", "task-branch"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unknown)
        try sandbox.git(["-C", tree.path, "branch", "--set-upstream-to=origin/main"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unpushedCommits(1))
        try sandbox.git(["-C", tree.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .noUnpushedCommits)
        try sandbox.git(["-C", tree.path, "update-ref", "-d", "refs/remotes/origin/main"])
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unknown)
    }

    @Test("Incomplete history and failed push checks remain unknown")
    func unknownPushStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        let head = try await ProcessRunner().run("/usr/bin/git", ["-C", repo.path, "rev-parse", "HEAD"])
        try head.write(to: repo.appendingPathComponent(".git/shallow"))
        #expect(try await GitWorktreeDetector.pushStatus(of: tree) == .unknown)
        #expect(try await GitWorktreeDetector.pushStatus(of: sandbox.home.appendingPathComponent("missing")) == .unknown)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitWorktreeDetector.pushStatus(of: tree)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled push check completed")
        } catch is CancellationError {
        }
    }

    @Test("Relative and stale worktree markers differ from submodules and ordinary repositories")
    func markerShapes() throws {
        let sandbox = try Sandbox()
        try sandbox.file("Project/.worktrees/task/.git", text: "gitdir: ../../.git/worktrees/task\n")
        try sandbox.file("Project/module/.git", text: "gitdir: ../.git/modules/module\n")
        try sandbox.file("Project/ordinary/.git/config", text: "[core]\n")
        try sandbox.file("Project/decoy/.git", text: "not a git marker")
        let root = sandbox.home.appendingPathComponent("Project")
        let found = try GitWorktreeDetector.roots(under: root, context: ScanContext())
        #expect(found.map(\.lastPathComponent) == ["task"])
    }

    @Test("Discovery respects exclusions, symbolic links, and cancellation")
    func discoveryGuards() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Project/.worktrees/task/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        let root = sandbox.home.appendingPathComponent("Project")
        let tree = root.appendingPathComponent(".worktrees/task")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: tree)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext()).count == 1)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext(excludedPaths: [tree.path])).isEmpty)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext(excludedPatterns: [".worktrees"])).isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GitWorktreeDetector.roots(under: root, context: ScanContext())
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled discovery completed")
        } catch is CancellationError {
        }
    }
}
