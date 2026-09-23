import Foundation

/// One source for known storage paths, ownership, descriptions, and removal policy.
public struct StorageRuleRegistry: Sendable {
    public enum Resolution: Sendable, Equatable {
        case known(StorageRule)
        case conflict([StorageRule])
        case unknown
    }

    public let rules: [StorageRule]

    public init(rules: [StorageRule]) { self.rules = rules }

    /// Specific paths win over parent rules. Equally specific rules must agree.
    public func resolve(_ url: URL, home: URL) -> Resolution {
        let home = home.standardizedFileURL
        let url = url.standardizedFileURL
        guard AppUninstallPlanner.isInside(url, root: home),
              !AppUninstallPlanner.isSymbolicLink(url),
              !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: home)
        else { return .unknown }
        let relative = Array(url.pathComponents.dropFirst(home.pathComponents.count))
        let matches = rules.filter { $0.matches(relative) }
        guard let depth = matches.map({ $0.components.count }).max() else { return .unknown }
        let deepest = matches.filter { $0.components.count == depth }
        let literalCount = deepest.map(\.literalComponentCount).max() ?? 0
        let best = deepest.filter { $0.literalComponentCount == literalCount }
            .sorted { $0.id < $1.id }
        guard let first = best.first else { return .unknown }
        return best.allSatisfy { $0 == first } ? .known(first) : .conflict(best)
    }

    func classify(_ original: FileEntry, home: URL, context: ScanContext) -> FileEntry {
        switch resolve(original.url, home: home) {
        case .known(let rule):
            let components = Array(original.url.standardizedFileURL.pathComponents.dropFirst(home.standardizedFileURL.pathComponents.count))
            let depth = components.count
            // A broad cache rule must not carry away more specific protected or differently owned storage.
            if rule.isRegenerable, rules.contains(where: { candidate in
                candidate.isValid && candidate.components.count > depth
                    && zip(candidate.components, components).allSatisfy { fnmatch($0.0, $0.1, 0) == 0 }
                    && (!candidate.isRegenerable || candidate.ownerRules != rule.ownerRules || candidate.category != rule.category)
            }) {
                var entry = original
                entry.storageRule = rule
                entry.isRegenerable = false
                entry.inventoryReason = "This folder contains storage with different removal rules. Select individual folders instead."
                return entry
            }
            return rule.apply(to: original, context: context, isRoot: depth == rule.components.count)
        case .conflict:
            var entry = original
            entry.isRegenerable = false
            entry.storageRule = nil
            entry.inventoryReason = "Storage rules disagree about this folder. Review it in Storage Explorer."
            entry.safeRemovalReviewReason = "Conflicting storage rules"
            return entry
        case .unknown:
            return original
        }
    }

    static let inheritedEvidence = StorageRule.Evidence(
        basis: .inheritedRule,
        reference: "Existing Scolo rules and fixture tests. This records prior behavior, not a new application compatibility test."
    )

    static let sandboxEvidence = StorageRule.Evidence(
        basis: .documented,
        reference: "Apple File System Programming Guide: sandbox containers and Library/Caches. https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html"
    )

    static func applicationRules(
        _ layout: AppDataCuration, identifier: String?, name: String,
        evidence: StorageRule.Evidence? = nil
    ) -> [StorageRule] {
        let evidence = evidence ?? layout.evidence
        let ownerRules: [FileEntry.OwnerRule] = identifier.map { [.bundleIdentifier($0)] } ?? []
        let category: CategoryID = tools.contains { $0.identifier == identifier } ? .aiTools : .applications
        let key = "application:\(identifier ?? name):\(layout.root)"
        var rules = [StorageRule(
            id: key + ":data", path: layout.root, owner: name, ownerRules: ownerRules,
            category: .applications, dataType: .userData, title: layout.remainderName,
            removalEffect: "Removes saved application data and settings.", evidence: evidence
        )]
        rules += layout.regenerable.map { path in
            let description = cacheDescription(for: String(path.split(separator: "/").last ?? "Cache"))
            return StorageRule(
                id: key + ":" + path, path: layout.root + "/" + path,
                owner: name, ownerRules: ownerRules, category: category, dataType: .cache,
                title: category == .aiTools ? "\(name) · \(description.name)" : nil,
                summary: category == .aiTools ? description.summary : nil,
                removalEffect: description.summary, evidence: evidence
            )
        }
        return rules
    }

    static func inventoryRule(_ root: InventoryRoot) -> StorageRule {
        return StorageRule(
            id: "ai-data:" + root.path, path: root.path, owner: root.owner, ownerRules: [],
            category: .aiTools, dataType: root.isWorktree ? .worktree : .userData,
            title: root.name, summary: root.summary,
            removalEffect: root.isWorktree
                ? "This folder can contain unfinished work, local commits, and files outside Git. Removal can also leave Git worktree records behind. Quit the owning tool first."
                : "This folder can contain conversations, attachments, or saved work. Removal can prevent you from opening previous sessions. Quit the owning tool first.",
            evidence: inheritedEvidence
        )
    }

    static func runtimeRule(_ runtime: DownloadedRuntime) -> StorageRule {
        StorageRule(
            id: "runtime:" + runtime.folder, path: ".cache/" + runtime.folder,
            owner: runtime.owner, ownerRules: [.bundleIdentifier(runtime.ownerIdentifier)],
            category: .aiTools, dataType: .downloadedTools, title: runtime.name,
            summary: runtime.summary, removalEffect: runtime.removalEffect, evidence: runtime.evidence
        )
    }

    static func supportCacheRule(_ cache: ApplicationSupportCache) -> StorageRule {
        StorageRule(
            id: "support-cache:" + cache.components.joined(separator: "/"),
            path: "Library/Application Support/" + cache.components.joined(separator: "/"),
            owner: cache.components[0], ownerRules: [.bundleIdentifierPrefix(cache.ownerIdentifierPrefix)],
            category: .systemCaches, dataType: .cache, title: cache.label,
            removalEffect: "The application recreates these files when needed.", evidence: cache.evidence
        )
    }

    /// Explicit rules exist even when the application is absent. Discovery still checks the filesystem.
    static func standard(home: URL) -> StorageRuleRegistry {
        var rules = curations.sorted { $0.key < $1.key }.flatMap { identifier, layout in
            applicationRules(layout, identifier: identifier,
                             name: tools.first { $0.identifier == identifier }?.name ?? identifier)
        }
        for tool in tools where curations[tool.identifier] == nil {
            if let layout = curation(bundleID: tool.identifier, baseName: tool.supportName, home: home) {
                rules += applicationRules(layout, identifier: tool.identifier, name: tool.name)
            }
        }
        rules += inventoryRoots.map(inventoryRule)
        rules += downloadedRuntimes.map(runtimeRule)
        rules += applicationSupportCaches.map(supportCacheRule)
        rules += photosLibraryResourceRules
        return StorageRuleRegistry(rules: rules)
    }
}
