import Foundation

/// Finds linked Git worktrees, including worktrees in hidden folders.
enum GitWorktreeDetector {
    private static let opaqueNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "vendor", ".build", "build",
        "target", ".venv", "venv", "Pods", "Library", ".Trash"
    ]

    /// A linked worktree points to Git metadata under a `worktrees` folder.
    /// Missing metadata can remain after the main repository is removed.
    static func isWorktree(_ directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(".git")
        guard let values = try? marker.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 16_384,
              let text = try? String(contentsOf: marker, encoding: .utf8),
              text.hasPrefix("gitdir: ") else { return false }
        let path = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n") else { return false }
        let metadata = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        return metadata.deletingLastPathComponent().lastPathComponent == "worktrees"
    }

    /// Stops at each worktree so nested files are counted once.
    static func roots(under folder: URL, context: ScanContext, maxDepth: Int = 8) throws -> [URL] {
        var found: [URL] = []
        func walk(_ directory: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard !context.isWithinExclusion(directory),
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard !context.isExcluded(child),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if isWorktree(child) {
                    found.append(child)
                } else if depth < maxDepth, !opaqueNames.contains(child.lastPathComponent),
                          !AppleMediaLibrary.contains(child, home: folder),
                          child.pathExtension != "app" {
                    try walk(child, depth: depth + 1)
                }
            }
        }
        try walk(folder, depth: 1)
        return found
    }

    /// Includes staged changes, unstaged changes, and untracked files.
    static func status(of directory: URL) async throws -> FileEntry.GitWorktreeStatus {
        try Task.checkCancellation()
        do {
            let output = try await ProcessRunner().run(
                "/usr/bin/git",
                ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", directory.path,
                 "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"],
                timeout: .seconds(5)
            )
            return output.isEmpty ? .clean : .uncommittedChanges
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .unavailable
        }
    }

    /// Uses the upstream branch when available. Detached worktrees use all remote-tracking branches.
    static func pushStatus(of directory: URL) async throws -> FileEntry.GitWorktreePushStatus {
        func git(_ arguments: [String]) async throws -> String {
            try Task.checkCancellation()
            let data = try await ProcessRunner().run(
                "/usr/bin/git",
                ["--no-optional-locks", "--no-lazy-fetch", "-C", directory.path] + arguments,
                timeout: .seconds(5)
            )
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            // Incomplete history cannot prove that a commit reached a remote branch.
            guard try await git(["rev-parse", "--is-shallow-repository"]) == "false" else { return .unknown }
            let remotes = try await git(["for-each-ref", "--format=%(refname)", "refs/remotes/"])
            guard !remotes.isEmpty else { return .unknown }
            let upstream: String?
            do {
                upstream = try await git(["rev-parse", "--symbolic-full-name", "@{upstream}"])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                upstream = nil
            }
            let comparison: [String]
            if let upstream {
                guard upstream.hasPrefix("refs/remotes/") else { return .unknown }
                comparison = ["HEAD", "^" + upstream, "--"]
            } else {
                // A branch without an upstream has no defined push destination.
                let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"])
                guard head == "HEAD" else { return .unknown }
                comparison = ["HEAD", "--not", "--remotes", "--"]
            }
            let output = try await git(["rev-list", "--count"] + comparison)
            guard let count = Int(output), count >= 0 else { return .unknown }
            return count == 0 ? .noUnpushedCommits : .unpushedCommits(count)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .unknown
        }
    }

    /// Moves worktree bytes from the parent remainder into review rows.
    static func addingWorktrees(to entry: FileEntry, context: ScanContext) async throws -> FileEntry {
        guard entry.kind == .folder else { return entry }
        var result = entry
        if isWorktree(entry.url) {
            result.parentDisplay += " · Git worktree"
            result.isRegenerable = false
            result.safetyCaveat = "Git worktree"
            result.gitWorktreeStatus = try await status(of: entry.url)
            result.gitWorktreePushStatus = try await pushStatus(of: entry.url)
            return result
        }
        for root in try roots(under: entry.url, context: context) {
            // Existing children own their complete trees.
            guard !entry.children.contains(where: {
                root.path == $0.url.path || root.path.hasPrefix($0.url.path + "/")
            }) else { continue }
            let measured = try await context.measurer.measure(root)
            guard measured.allocatedBytes > 0, !measured.containsProtectedPattern else { continue }
            let bytes = min(result.allocatedBytes, measured.allocatedBytes)
            result.allocatedBytes -= bytes
            result.children.append(FileEntry(
                url: root,
                parentDisplay: FileEntry.abbreviate(root.deletingLastPathComponent().path) + " · Git worktree",
                kind: .folder,
                allocatedBytes: bytes,
                lastOpened: DocumentsFilesScanner.lastOpenedDate(for: root),
                safetyCaveat: "Git worktree",
                gitWorktreeStatus: try await status(of: root),
                gitWorktreePushStatus: try await pushStatus(of: root)
            ))
        }
        return result
    }
}
