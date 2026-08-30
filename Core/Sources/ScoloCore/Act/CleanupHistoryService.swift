import Foundation

/// The current state of one removal receipt.
public enum CleanupHistoryState: String, Sendable, Equatable, CaseIterable {
    case availableInTrash
    case inTrash
    case restored
    case removedPermanently
    case noLongerInTrash
    case failed
}

/// One readable item from the append-only removal log.
public struct CleanupHistoryItem: Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let originalURL: URL
    public let bytes: Int64
    public let state: CleanupHistoryState

    public var name: String {
        originalURL.lastPathComponent
    }

    init(record: RemovalRecord, state: CleanupHistoryState, occurrence: Int) {
        timestamp = record.timestamp
        originalURL = URL(fileURLWithPath: record.originalPath)
        bytes = record.bytes
        self.state = state
        id = ([
            record.timestamp.ISO8601Format(),
            record.disposition.rawValue,
            record.originalPath,
            record.trashedPath ?? "",
            record.trashedIdentity ?? "",
        ] + [String(occurrence)]).joined(separator: "\u{1F}")
    }
}

/// The figures and rows for Cleanup History.
public struct CleanupHistorySummary: Sendable, Equatable {
    public let removedBytes: Int64
    public let removedCount: Int
    public let permanentlyRemovedCount: Int
    public let failedCount: Int
    public let availableInTrashCount: Int
    public let items: [CleanupHistoryItem]

    public init(
        removedBytes: Int64 = 0,
        removedCount: Int = 0,
        permanentlyRemovedCount: Int = 0,
        failedCount: Int = 0,
        availableInTrashCount: Int = 0,
        items: [CleanupHistoryItem] = []
    ) {
        self.removedBytes = removedBytes
        self.removedCount = removedCount
        self.permanentlyRemovedCount = permanentlyRemovedCount
        self.failedCount = failedCount
        self.availableInTrashCount = availableInTrashCount
        self.items = items
    }
}

/// Reads cleanup history and checks receipts against items in the Trash.
public struct CleanupHistoryService: Sendable {
    private let log: RemovalLog

    public init(log: RemovalLog = RemovalLog()) {
        self.log = log
    }

    /// Returns the newest receipts first. Restore tombstones retire only the exact
    /// older Trash receipt that they consumed.
    public func summary(limit: Int = 5_000) -> CleanupHistorySummary {
        let records = log.recentEntries(limit: limit)
        var retiredByTrashPath: [String: Int] = [:]
        var items: [CleanupHistoryItem] = []
        var removedBytes: Int64 = 0
        var removedCount = 0
        var permanentlyRemovedCount = 0
        var failedCount = 0
        var availableInTrashCount = 0
        var occurrences: [String: Int] = [:]

        for record in records {
            switch record.disposition {
            case .restored:
                guard let path = record.trashedPath else { continue }
                retiredByTrashPath[canonicalPath(path), default: 0] += 1

            case .trashed:
                removedBytes += max(0, record.bytes)
                removedCount += 1
                let state = trashState(
                    for: record,
                    retiredByTrashPath: &retiredByTrashPath
                )
                if state == .availableInTrash { availableInTrashCount += 1 }
                items.append(item(record, state: state, occurrences: &occurrences))

            case .deleted:
                removedBytes += max(0, record.bytes)
                removedCount += 1
                permanentlyRemovedCount += 1
                items.append(item(record, state: .removedPermanently, occurrences: &occurrences))

            case .failed:
                failedCount += 1
                items.append(item(record, state: .failed, occurrences: &occurrences))
            }
        }

        return CleanupHistorySummary(
            removedBytes: removedBytes,
            removedCount: removedCount,
            permanentlyRemovedCount: permanentlyRemovedCount,
            failedCount: failedCount,
            availableInTrashCount: availableInTrashCount,
            items: items
        )
    }

    private func trashState(
        for record: RemovalRecord,
        retiredByTrashPath: inout [String: Int]
    ) -> CleanupHistoryState {
        guard let path = record.trashedPath else { return .noLongerInTrash }
        let key = canonicalPath(path)
        if let count = retiredByTrashPath[key], count > 0 {
            if count == 1 { retiredByTrashPath.removeValue(forKey: key) }
            else { retiredByTrashPath[key] = count - 1 }
            return .restored
        }

        let url = URL(fileURLWithPath: path)
        guard let currentIdentity = FileIdentity.of(url) else { return .noLongerInTrash }
        guard let identity = record.trashedIdentity else { return .inTrash }
        return currentIdentity == identity ? .availableInTrash : .inTrash
    }

    private func item(
        _ record: RemovalRecord,
        state: CleanupHistoryState,
        occurrences: inout [String: Int]
    ) -> CleanupHistoryItem {
        let key = [
            record.timestamp.ISO8601Format(),
            record.disposition.rawValue,
            record.originalPath,
            record.trashedPath ?? "",
            record.trashedIdentity ?? "",
        ].joined(separator: "\u{1F}")
        let occurrence = occurrences[key, default: 0]
        occurrences[key] = occurrence + 1
        return CleanupHistoryItem(record: record, state: state, occurrence: occurrence)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
