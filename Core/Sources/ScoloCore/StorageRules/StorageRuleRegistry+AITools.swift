import Foundation

extension StorageRuleRegistry {
    struct Tool {
        let name: String
        let identifier: String
        let supportName: String
    }

    static let tools = [
        Tool(name: "Claude", identifier: "com.anthropic.claudefordesktop", supportName: "Claude"),
        Tool(name: "Codex", identifier: "com.openai.codex", supportName: "Codex"),
        Tool(name: "Cursor", identifier: "com.todesktop.230313mzl4w4u92", supportName: "Cursor")
    ]

    struct DownloadedRuntime {
        let folder: String
        let ownerIdentifier: String
        let name: String
        let owner: String
        let summary: String
        let removalEffect: String
        let evidence: StorageRule.Evidence
    }

    /// Installer-managed tools that the owning application can download again.
    static let downloadedRuntimes = [
        DownloadedRuntime(
            folder: "codex-runtimes", ownerIdentifier: "com.openai.codex", name: "Codex · Downloaded runtime",
            owner: "Codex", summary: "Downloaded tools for AI tasks. Removal requires another download before use.",
            removalEffect: "Requires another runtime download before use.",
            evidence: .init(basis: .sourceReview, reference: "Codex desktop primary runtime installer: download, cache validation, and reinstall paths. Reviewed 2026-09-23.")
        )
    ]

    static var dotCacheFolderNames: Set<String> { Set(downloadedRuntimes.map(\.folder)) }

    struct InventoryRoot {
        let path: String
        let owner: String
        let name: String
        let summary: String
        var grouped = false
        var isWorktree = false
    }

    static let inventoryRoots: [InventoryRoot] = [
        .init(path: ".codex/sessions", owner: "Codex", name: "Codex sessions", summary: "Saved conversations and records used to resume tasks"),
        .init(path: ".codex/archived_sessions", owner: "Codex", name: "Codex archived sessions", summary: "Conversations kept from archived tasks"),
        .init(path: ".codex/attachments", owner: "Codex", name: "Codex attachments", summary: "Files and images saved with conversations"),
        .init(path: ".codex/worktrees", owner: "Codex", name: "Codex worktrees", summary: "Separate project copies that can contain unfinished work", grouped: true, isWorktree: true),
        .init(path: ".claude/projects", owner: "Claude", name: "Claude Code projects", summary: "Saved conversations and data for each project", grouped: true),
        .init(path: ".claude/file-history", owner: "Claude", name: "Claude Code file history", summary: "Earlier file versions saved during editing"),
        .init(path: ".cursor/projects", owner: "Cursor", name: "Cursor project data", summary: "Saved data associated with individual projects", grouped: true),
        .init(path: ".cursor/worktrees", owner: "Cursor", name: "Cursor worktrees", summary: "Separate project copies that can contain unfinished work", grouped: true, isWorktree: true),
        .init(path: "Library/Application Support/Cursor/User/workspaceStorage", owner: "Cursor", name: "Cursor workspace state", summary: "Saved editor and extension state for each workspace", grouped: true),
        .init(path: "Library/Application Support/Claude/claude-code-sessions", owner: "Claude", name: "Claude desktop sessions", summary: "Saved coding sessions from the desktop app"),
        .init(path: "Library/Application Support/Claude/local-agent-mode-sessions", owner: "Claude", name: "Claude local sessions", summary: "Saved local task sessions and related working data")
    ]

    static func cacheDescription(for name: String) -> (name: String, summary: String) {
        switch name {
        case "Cache":
            ("Downloaded content", "Downloaded content kept to reduce loading time")
        case "Code Cache":
            ("Code cache", "Compiled app code kept to reduce loading time")
        case "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "DawnCache":
            ("Graphics cache", "Temporary graphics data used to draw the app")
        case "Crashpad":
            ("Crash reports", "Crash reports and diagnostic files")
        case "component_crx_cache":
            ("Component downloads", "Downloaded app components kept for reuse")
        default:
            (name, "Temporary app files that can be created again")
        }
    }

}
