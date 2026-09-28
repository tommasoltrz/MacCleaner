import Foundation

extension StorageRule {
    /// Removal needs one exact application owner and recorded evidence.
    var removalOwner: String? {
        guard isValid, removalPolicy == .applicationData, evidence.basis != .unverified,
              dataType != .worktree, dataType != .managedLibrary, dataType != .unknown,
              ownerRules.count == 1, case .bundleIdentifier(let identifier) = ownerRules[0]
        else { return nil }
        return AppUninstallPlanner.verifiedBundleIdentifier(identifier)
    }
}

extension StorageRuleRegistry {
    func knownRule(_ url: URL, home: URL) -> StorageRule? {
        guard case .known(let rule) = resolve(url, home: home) else { return nil }
        return rule
    }

    /// Returns existing, directly owned paths. Shared and protected storage does not establish application ownership.
    func applicationCandidates(home: URL, identifiers: Set<String>? = nil) -> [AppUninstallPlanner.Candidate] {
        var result: [AppUninstallPlanner.Candidate] = []
        for rule in rules {
            guard let owner = rule.removalOwner, identifiers?.contains(owner) ?? true else { continue }
            for url in Self.expand(rule.path, under: home) {
                guard FileManager.default.fileExists(atPath: url.path),
                      case .known(let resolved) = resolve(url, home: home), resolved.removalOwner == owner else { continue }
                result.append(.init(url: url, category: resolved.isRegenerable ? .caches : .support,
                                    content: resolved.isRegenerable ? .regenerable : .userData,
                                    ownerBundleIdentifier: owner))
            }
        }
        // One parent owns its descendants. Partitioning below keeps protected subfolders separate.
        var roots: [AppUninstallPlanner.Candidate] = []
        for candidate in result.sorted(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) {
            if !roots.contains(where: { candidate.url.standardizedFileURL.path == $0.url.standardizedFileURL.path || AppUninstallPlanner.isInside(candidate.url, root: $0.url) }) {
                roots.append(candidate)
            }
        }
        return roots
    }

    func hasRemovalBoundary(under url: URL, home: URL, owner: String) -> Bool {
        guard AppUninstallPlanner.isInside(url, root: home) else { return false }
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst(home.standardizedFileURL.pathComponents.count))
        return rules.contains { rule in
            rule.isValid && rule.components.count > components.count
                && zip(rule.components, components).allSatisfy { fnmatch($0.0, $0.1, 0) == 0 }
                && (rule.removalOwner != owner || hasConflictingRule(rule))
        }
    }

    private func hasConflictingRule(_ rule: StorageRule) -> Bool {
        rules.contains { other in
            guard other != rule, other.isValid, other.components.count == rule.components.count,
                  other.literalComponentCount == rule.literalComponentCount else { return false }
            return zip(other.components, rule.components).allSatisfy { left, right in
                let leftPattern = left.contains("*") || left.contains("?") || left.contains("[")
                let rightPattern = right.contains("*") || right.contains("?") || right.contains("[")
                return (leftPattern && rightPattern) || fnmatch(left, right, 0) == 0 || fnmatch(right, left, 0) == 0
            }
        }
    }

    func permitsApplicationRemoval(_ url: URL, home: URL, owner: String) -> Bool {
        switch resolve(url, home: home) {
        case .known(let rule):
            guard rule.removalOwner == owner else { return false }
        case .conflict: return false
        case .unknown: break // Existing bundle-identifier paths retain their independent ownership checks.
        }
        return !hasRemovalBoundary(under: url, home: home, owner: owner)
    }

    struct RemovalPartition {
        var candidates: [AppUninstallPlanner.Candidate] = []
        var preserved: [URL] = []
        var unreadableCount = 0
    }

    /// Splits only at rule boundaries. A parent cannot remove saved work through a broader application rule.
    func partitionForRemoval(_ candidates: [AppUninstallPlanner.Candidate], home: URL) throws -> RemovalPartition {
        var result = RemovalPartition()
        var seen = Set<String>()
        func visit(_ candidate: AppUninstallPlanner.Candidate) throws {
            try Task.checkCancellation()
            let url = candidate.url.standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            if AppUninstallPlanner.isSymbolicLink(url)
                || (AppUninstallPlanner.isInside(url, root: home)
                    && AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: home)) {
                result.preserved.append(url)
                return
            }
            switch resolve(url, home: home) {
            case .known(let rule) where rule.removalOwner != candidate.ownerBundleIdentifier:
                result.preserved.append(url)
                return
            case .conflict:
                result.preserved.append(url)
                return
            default: break
            }
            guard hasRemovalBoundary(under: url, home: home, owner: candidate.ownerBundleIdentifier) else {
                if case .known(let rule) = resolve(url, home: home) {
                    result.candidates.append(.init(url: url, category: rule.isRegenerable ? .caches : candidate.category,
                                                   content: rule.isRegenerable ? .regenerable : candidate.content,
                                                   ownerBundleIdentifier: candidate.ownerBundleIdentifier))
                } else {
                    result.candidates.append(candidate)
                }
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            } catch {
                result.preserved.append(url)
                result.unreadableCount += 1
                return
            }
            for child in children.sorted(by: { $0.path < $1.path }) {
                try visit(.init(url: child, category: candidate.category, content: candidate.content,
                                ownerBundleIdentifier: candidate.ownerBundleIdentifier))
            }
        }
        for candidate in candidates { try visit(candidate) }
        return result
    }
}
