import Foundation

/// Keeps folder measurements available while changed sizes are checked again.
public struct StorageExplorerCache: Sendable {
    private var snapshots: [String: StorageExplorerSnapshot] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 32) { self.limit = max(1, limit) }

    public mutating func snapshot(for url: URL) -> StorageExplorerSnapshot? {
        let key = url.standardizedFileURL.path
        guard let snapshot = snapshots[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return snapshot
    }

    public mutating func store(_ snapshot: StorageExplorerSnapshot) {
        let key = snapshot.directory.standardizedFileURL.path
        snapshots[key] = snapshot
        order.removeAll { $0 == key }
        order.append(key)
        var entryCount = snapshots.values.reduce(0) { $0 + $1.items.count }
        while order.count > limit || (entryCount > 50_000 && order.count > 1) {
            entryCount -= snapshots.removeValue(forKey: order.removeFirst())?.items.count ?? 0
        }
    }

    public mutating func invalidate() {
        for key in snapshots.keys { snapshots[key]?.isEstimated = true }
    }

    public mutating func invalidate(relatedTo url: URL) {
        let path = url.standardizedFileURL.path
        for key in snapshots.keys {
            if key == path || key.hasPrefix(path == "/" ? "/" : path + "/")
                || path.hasPrefix(key == "/" ? "/" : key + "/") {
                snapshots[key]?.isEstimated = true
            }
        }
    }

    public mutating func remove(_ url: URL) {
        let key = url.standardizedFileURL.path
        snapshots.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Apply only confirmed moves. Folder sizes remain estimates until the next measurement.
    public mutating func applyRemovals(_ records: [RemovalRecord], items: [StorageExplorerItem]) {
        for record in records where record.disposition == .trashed {
            guard let destinationPath = record.trashedPath,
                  let removed = items.first(where: { $0.url.path == record.originalPath }) else {
                invalidate()
                continue
            }
            let source = Route(URL(fileURLWithPath: record.originalPath))
            let destination = Route(URL(fileURLWithPath: destinationPath))
            for key in Array(snapshots.keys) {
                guard var snapshot = snapshots[key] else { continue }
                let directoryPath = snapshot.directory.standardizedFileURL.path
                if directoryPath == source.path || directoryPath.hasPrefix(source.path + "/") {
                    remove(snapshot.directory)
                    continue
                }
                let directoryIdentity = FileIdentity.of(snapshot.directory)
                let containsSource = source.containsAncestor(snapshot.directory, identity: directoryIdentity)
                let containsDestination = destination.containsAncestor(snapshot.directory, identity: directoryIdentity)
                guard containsSource || containsDestination else { continue }

                snapshot.items = snapshot.items.compactMap { item -> StorageExplorerItem? in
                    if source.isDirectChild(of: snapshot.directory, identity: directoryIdentity),
                       item.url.lastPathComponent == source.url.lastPathComponent { return nil }
                    var item = item
                    let sourceInside = source.containsAncestor(item.url, identity: item.identity)
                    let destinationInside = destination.containsAncestor(item.url, identity: item.identity)
                    let direction = (destinationInside ? 1 : 0) - (sourceInside ? 1 : 0)
                    item.allocatedBytes = max(0, item.allocatedBytes + Int64(direction) * record.bytes)
                    item.fileCount = max(0, item.fileCount + direction * removed.fileCount)
                    return item
                }
                if destination.isDirectChild(of: snapshot.directory, identity: directoryIdentity) {
                    var moved = removed
                    moved.url = snapshot.directory.appendingPathComponent(destination.url.lastPathComponent)
                    moved.name = destination.url.lastPathComponent
                    moved.identity = record.trashedIdentity
                    moved.allocatedBytes = record.bytes
                    moved.protectionReason = .trash
                    snapshot.items.removeAll { $0.id == moved.id }
                    snapshot.items.append(moved)
                } else if containsDestination,
                          !snapshot.items.contains(where: { destination.containsAncestor($0.url, identity: $0.identity) }),
                          let child = destination.child(of: snapshot.directory, identity: directoryIdentity) {
                    snapshot.items.append(StorageExplorerItem(
                        url: child, kind: .folder, allocatedBytes: record.bytes,
                        fileCount: removed.fileCount, identity: FileIdentity.of(child),
                        protectionReason: StorageExplorerService.isTrashLocation(child) ? .trash : .unavailable
                    ))
                }
                snapshot.allocatedBytes = snapshot.items.reduce(0) { $0 + $1.allocatedBytes }
                snapshot.fileCount = snapshot.items.reduce(0) { $0 + $1.fileCount }
                snapshot.unreadableCount = snapshot.items.reduce(0) { $0 + $1.unreadableCount }
                snapshot.isEstimated = true
                snapshots[key] = snapshot
            }
        }
    }

    /// Directory identities match alternate volume paths, including the macOS `.nofollow` path.
    private struct Route {
        let url: URL
        let path: String
        let parent: URL
        let parentIdentity: String?
        let ancestorIdentities: Set<String>

        init(_ url: URL) {
            self.url = url.standardizedFileURL
            path = self.url.path
            parent = self.url.deletingLastPathComponent()
            parentIdentity = FileIdentity.of(parent)
            var ancestor = parent
            var identities = Set<String>()
            while true {
                if let identity = FileIdentity.of(ancestor) { identities.insert(identity) }
                let next = ancestor.deletingLastPathComponent()
                if next.path == ancestor.path { break }
                ancestor = next
            }
            ancestorIdentities = identities
        }

        func containsAncestor(_ candidate: URL, identity: String?) -> Bool {
            let candidatePath = candidate.standardizedFileURL.path
            if path.hasPrefix(candidatePath == "/" ? "/" : candidatePath + "/") { return true }
            return identity.map { ancestorIdentities.contains($0) } ?? false
        }

        func isDirectChild(of directory: URL, identity: String?) -> Bool {
            directory.standardizedFileURL.path == parent.path
                || (identity != nil && identity == parentIdentity)
        }

        func child(of directory: URL, identity: String?) -> URL? {
            var candidate = parent
            while candidate.path != "/" {
                let ancestor = candidate.deletingLastPathComponent()
                if ancestor.path == directory.standardizedFileURL.path
                    || (identity != nil && FileIdentity.of(ancestor) == identity) {
                    return directory.appendingPathComponent(candidate.lastPathComponent)
                }
                candidate = ancestor
            }
            return nil
        }
    }
}
