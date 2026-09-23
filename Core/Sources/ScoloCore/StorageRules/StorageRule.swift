import Foundation

/// Describes storage. Live process state and filesystem access do not belong in a rule.
public struct StorageRule: Sendable, Equatable {
    public enum DataType: Sendable, Equatable {
        case cache, downloadedTools, userData, worktree, managedLibrary, unknown
    }

    public struct Evidence: Sendable, Equatable {
        public enum Basis: Sendable, Equatable {
            case documented, sourceReview, localInspection, inheritedRule, unverified
        }
        public let basis: Basis
        public let reference: String
    }

    public let id: String
    /// A home-relative path. Wildcards match one component, never a path separator.
    public let path: String
    public let owner: String
    public let ownerRules: [FileEntry.OwnerRule]
    public let category: CategoryID
    public let dataType: DataType
    public var title: String? = nil
    public var summary: String? = nil
    public let removalEffect: String
    public let evidence: Evidence

    public var isRegenerable: Bool {
        isValid && evidence.basis != .unverified && (dataType == .cache || dataType == .downloadedTools)
    }

    var components: [String] { path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }

    var isValid: Bool {
        !id.isEmpty && !owner.isEmpty && !evidence.reference.isEmpty && !removalEffect.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("**") }
    }

    func matches(_ relativeComponents: [String]) -> Bool {
        let pattern = components
        guard isValid, relativeComponents.count >= pattern.count else { return false }
        return zip(pattern, relativeComponents).allSatisfy { fnmatch($0.0, $0.1, 0) == 0 }
    }

    var literalComponentCount: Int {
        components.filter { !$0.contains("*") && !$0.contains("?") && !$0.contains("[") }.count
    }

    /// Keeps the same policy for scanner rows, badges, and removal ownership checks.
    func apply(to original: FileEntry, context: ScanContext, isRoot: Bool = true) -> FileEntry {
        var entry = original
        guard isValid else {
            entry.isRegenerable = false
            entry.inventoryReason = "This storage rule is invalid. Review the folder in Storage Explorer."
            return entry
        }
        entry.storageRule = self
        entry.ownerRules = ownerRules
        entry.isRegenerable = isRegenerable
        if isRoot, let title { entry.displayName = title }
        if let summary { entry.contentDescription = summary }
        if dataType == .userData || dataType == .worktree {
            if entry.protectionReason == nil { entry.protectionReason = .userData }
        }
        if dataType == .managedLibrary {
            entry.inventoryReason = removalEffect
        }
        if evidence.basis == .unverified {
            entry.safeRemovalReviewReason = "This storage rule needs verification"
        }
        entry.inUseBy = context.runningOwner(for: entry) ?? original.inUseBy
        return entry
    }
}
