import Foundation

/// Measures known AI tool storage without reading conversation contents.
public struct AIToolsScanner: CategoryScanner {
    public let id = CategoryID.aiTools
    private let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    typealias InventoryRoot = StorageRuleRegistry.InventoryRoot
    static let inventoryRoots = StorageRuleRegistry.inventoryRoots

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var entries: [FileEntry] = []
        var unreadable = 0
        let manager = FileManager.default

        let registry = StorageRuleRegistry.standard(home: home)
        var seen = Set<String>()
        for rule in registry.rules where rule.category == id && (rule.dataType == .cache || rule.dataType == .downloadedTools) {
            try Task.checkCancellation()
            let tool = StorageRuleRegistry.tools.first { $0.name == rule.owner }
            let appPaths = context.runningApplicationPaths.filter { path in
                guard let tool else { return false }
                let url = URL(fileURLWithPath: path)
                return Bundle(url: url)?.bundleIdentifier == tool.identifier
                    || url.deletingPathExtension().lastPathComponent == tool.supportName
            }
            guard !appPaths.contains(where: { context.isExcluded(URL(fileURLWithPath: $0)) }) else { continue }
            let fallbackOwner = appPaths.sorted().first.map {
                FileEntry.RunningOwner(name: rule.owner, bundleIdentifier: tool?.identifier, bundlePath: $0)
            }
            for url in StorageRuleRegistry.expand(rule.path, under: home) {
                try Task.checkCancellation()
                guard seen.insert(url.path).inserted, directPath(url), !context.isExcluded(url),
                      manager.fileExists(atPath: url.path) else { continue }
                let size = try await context.measurer.measure(url)
                unreadable += size.unreadableCount
                guard size.allocatedBytes > 0, !size.containsProtectedPattern, size.unreadableCount == 0 else { continue }
                entries.append(registry.classify(FileEntry(
                    url: url, kind: .cache, allocatedBytes: size.allocatedBytes,
                    lastOpened: lastOpenedDate(for: url), inUseBy: fallbackOwner
                ), home: home, context: context))
            }
        }

        var roots = Self.inventoryRoots
        roots += try projectWorktrees(context: context, unreadable: &unreadable)
        for descriptor in roots {
            try Task.checkCancellation()
            let root = home.appendingPathComponent(descriptor.path)
            guard directPath(root), !context.isExcluded(root), manager.fileExists(atPath: root.path) else { continue }
            let rule = StorageRuleRegistry.inventoryRule(descriptor)
            let reason = rule.removalEffect
            var children: [FileEntry] = []
            var bytes: Int64 = 0
            var incomplete = false
            if descriptor.grouped {
                do {
                    _ = try manager.contentsOfDirectory(atPath: root.path)
                } catch {
                    unreadable += 1
                    continue
                }
                let measured = try await context.measurer.measureChildren(of: root)
                for (url, size) in measured {
                    unreadable += size.unreadableCount
                    guard directPath(url), !context.isExcluded(url), !size.containsProtectedPattern,
                          size.unreadableCount == 0 else { incomplete = true; continue }
                    guard size.allocatedBytes > 0 else { continue }
                    children.append(rule.apply(to: FileEntry(
                        url: url, contentDescription: descriptor.summary, kind: .folder, allocatedBytes: size.allocatedBytes,
                        lastOpened: lastOpenedDate(for: url), protectionReason: .userData, userDataRemovalWarning: reason
                    ), context: context, isRoot: false))
                }
                children.sort { $0.allocatedBytes > $1.allocatedBytes }
            } else {
                let size = try await context.measurer.measure(root)
                unreadable += size.unreadableCount
                guard !size.containsProtectedPattern, size.unreadableCount == 0 else { continue }
                bytes = size.allocatedBytes
            }
            guard bytes > 0 || !children.isEmpty else { continue }
            entries.append(rule.apply(to: FileEntry(
                url: root, displayName: descriptor.name,
                parentDisplay: FileEntry.abbreviate(root.path),
                contentDescription: descriptor.summary,
                kind: .folder, allocatedBytes: bytes,
                lastOpened: children.compactMap(\.lastOpened).max() ?? lastOpenedDate(for: root),
                protectionReason: .userData,
                inventoryReason: incomplete ? "Some contents are protected or unreadable. Select individual rows instead." : nil,
                userDataRemovalWarning: reason, childCount: children.isEmpty ? nil : children.count, children: children
            ), context: context))
        }
        return ScanCategoryResult(
            categoryID: id, totalBytes: entries.reduce(0) { $0 + $1.displayBytes }, entries: entries,
            availability: entries.isEmpty
                ? (unreadable > 0 ? .unavailable(reason: "Scolo cannot read AI tool storage. Check folder access and scan again.") : .empty)
                : .available,
            unreadableCount: unreadable
        )
    }

    private func directPath(_ url: URL) -> Bool {
        AppUninstallPlanner.isInside(url, root: home)
            && !AppUninstallPlanner.isSymbolicLink(url)
            && !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: home)
    }

    /// Checks two project levels. Dependency folders and symbolic links are never searched.
    private func projectWorktrees(context: ScanContext, unreadable: inout Int) throws -> [InventoryRoot] {
        var found: [InventoryRoot] = []
        let manager = FileManager.default
        let skipped: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "Library"]
        func visit(_ folder: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard directPath(folder), !context.isWithinExclusion(folder) else { return }
            let worktrees = folder.appendingPathComponent(".claude/worktrees")
            if directPath(worktrees), manager.fileExists(atPath: worktrees.path) {
                let relative = String(worktrees.standardizedFileURL.path.dropFirst(home.path.count + 1))
                found.append(.init(path: relative, owner: "Claude", name: "Claude worktrees · \(folder.lastPathComponent)", summary: "Separate project copies that can contain unfinished work", grouped: true, isWorktree: true))
            }
            guard depth > 0, manager.fileExists(atPath: folder.path) else { return }
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            } catch { unreadable += 1; return }
            for child in children where !skipped.contains(child.lastPathComponent) && child.pathExtension.isEmpty {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                try visit(child, depth: depth - 1)
            }
        }
        for name in ["Documents", "Developer", "Code", "Projects", "repos", "GitHub", "src", "Work"] {
            try visit(home.appendingPathComponent(name), depth: 2)
        }
        return found
    }
}
