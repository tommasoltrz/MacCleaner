import Foundation

/// Moves reviewed Storage Explorer rows to the Trash.
public struct StorageExplorerRemovalService: Sendable {
    private let cleanup: CleanupService

    public init(cleanup: CleanupService = CleanupService()) {
        self.cleanup = cleanup
    }

    public func remove(
        _ items: [StorageExplorerItem],
        from directory: URL,
        keepReceipt: Bool = true
    ) async throws -> CleanupOutcome {
        let parent = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>()
        var entries: [FileEntry] = []
        var identities: [FileEntry.ID: String] = [:]
        var outcome = CleanupOutcome()

        for item in items where seen.insert(item.id).inserted {
            let itemParent = item.url.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard itemParent == parent,
                  item.isRemovable,
                  let identity = item.identity,
                  FileIdentity.of(item.url) == identity
            else {
                outcome.failed.append(item.url.path)
                continue
            }

            let entry = FileEntry(
                url: item.url,
                displayName: item.name,
                kind: item.kind == .folder ? .folder : .file,
                allocatedBytes: item.allocatedBytes,
                childCount: item.fileCount
            )
            entries.append(entry)
            identities[entry.id] = identity
        }

        let removed = try await cleanup.remove(
            entries: entries,
            trashFirst: true,
            keepReceipt: keepReceipt,
            expectedIdentities: identities
        )
        outcome.merge(removed)
        return outcome
    }
}
