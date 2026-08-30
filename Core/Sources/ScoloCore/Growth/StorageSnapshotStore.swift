import Foundation

/// The ring of dated measurements, one JSON file per snapshot in
/// `~/Library/Application Support/Scolo/storage-history/`.
///
/// One file per snapshot, not one document holding all of them: a document has to be
/// rewritten whole on every save, so an interrupted write costs the entire history
/// instead of one measurement — the same reasoning that made ``RemovalLog``
/// line-oriented. It also means the retention rules are file deletions, which are
/// atomic on their own.
///
/// ### Retention
///
/// Applied after every save, in this order:
///
/// 1. **The two most recent measurements always survive.** Without this rule the
///    hour thinning below deletes the launch measurement as soon as the user presses
///    "Measure Again" fifteen minutes later, and the Dashboard reports "First
///    measurement" straight after the user's second one.
/// 2. **One measurement per hour**, the newest in the hour. A measurement whose
///    trigger is ``SnapshotTrigger/removal`` is never thinned: it is the baseline
///    that "since the last clean-up" reads, and it is worth more than the launch
///    measurement that follows it.
/// 3. **Nothing older than 30 days.**
/// 4. **At most 240 files**, oldest deleted first.
///
/// A file this store cannot decode is skipped, counted, and left alone. It is not
/// deleted: an unreadable file is almost certainly one a different version of the
/// app wrote, and deleting the other version's history to tidy up a directory is not
/// this store's decision to make.
public struct StorageSnapshotStore: Sendable {

    /// Measurements older than this are dropped.
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    /// A hard stop on the number of files.
    public static let maximumCount = 240

    /// How many of the newest measurements survive the hour thinning.
    ///
    /// Two, because "previous measurement" is one of the three baselines and it must
    /// resolve as soon as two measurements exist.
    public static let denseTailCount = 2

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(
        directory: URL = StorageSnapshotStore.defaultDirectory,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.now = now
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Scolo", isDirectory: true)
            .appendingPathComponent("storage-history", isDirectory: true)
    }

    // MARK: - Writing

    /// Stores one measurement, then applies the retention rules.
    public func save(_ snapshot: StorageSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL(for: snapshot), options: .atomic)
        prune()
    }

    /// Removes every stored measurement. Preferences offers this beside "Rebuild the
    /// size index", so the user can start a new history after changing what is on
    /// the disk deliberately.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in jsonFiles() {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `20260827T091203Z-launch.json`.
    ///
    /// The timestamp carries no colons, which Finder renders as slashes, and the
    /// trigger is last so a listing can be read at a glance.
    public func fileURL(for snapshot: StorageSnapshot) -> URL {
        let stamp = snapshot.measuredAt.formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .omitted,
                timeSeparator: .omitted,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
        return directory.appendingPathComponent("\(stamp)-\(snapshot.trigger.rawValue).json")
    }

    // MARK: - Reading

    /// Every stored measurement, newest first.
    public func load() -> [StorageSnapshot] {
        loadWithDiagnostics().snapshots
    }

    /// The same read, with the count of files that could not be decoded.
    ///
    /// Surfaced rather than swallowed for the same reason `unreadableCount` is:
    /// a history with a hole in it must be able to say so.
    public func loadWithDiagnostics() -> (snapshots: [StorageSnapshot], unreadableCount: Int) {
        var snapshots: [StorageSnapshot] = []
        var unreadable = 0
        for url in jsonFiles() {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? Self.decoder.decode(StorageSnapshot.self, from: data)
            else {
                unreadable += 1
                continue
            }
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.measuredAt > $1.measuredAt }
        return (snapshots, unreadable)
    }

    private func jsonFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    // MARK: - Retention

    private func prune() {
        let stored = loadWithDiagnostics().snapshots  // newest first
        let survivors = Self.survivors(of: stored, now: now())
        let keptIDs = Set(survivors.map(\.id))

        for snapshot in stored where !keptIDs.contains(snapshot.id) {
            try? FileManager.default.removeItem(at: fileURL(for: snapshot))
        }
    }

    /// The retention rules as one pure function, so they can be tested without a
    /// filesystem and read without one either.
    ///
    /// - Parameter snapshots: newest first.
    static func survivors(of snapshots: [StorageSnapshot], now: Date) -> [StorageSnapshot] {
        var kept: [StorageSnapshot] = []
        var claimedHours = Set<Date>()

        for (index, snapshot) in snapshots.enumerated() {
            let isDenseTail = index < denseTailCount
            let hour = Self.hour(of: snapshot.measuredAt)
            let hourIsFree = claimedHours.insert(hour).inserted

            // A clean-up baseline is never thinned, whichever hour it shares.
            guard isDenseTail || hourIsFree || snapshot.trigger == .removal else { continue }
            guard now.timeIntervalSince(snapshot.measuredAt) <= maximumAge else { continue }
            kept.append(snapshot)
        }

        if kept.count > maximumCount { kept.removeLast(kept.count - maximumCount) }
        return kept
    }

    /// The start of the hour a date falls in, in UTC.
    ///
    /// UTC and not the user's calendar, so a daylight-saving change cannot merge two
    /// hours of history into one or split one into two.
    private static func hour(of date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 3600).rounded(.down) * 3600)
    }

    // MARK: - Coding

    /// Dates are encoded the way `JSONEncoder` does by default, and not as ISO 8601
    /// text, because ISO 8601 drops sub-seconds: a snapshot would not equal itself
    /// after a round trip, and its filename would change on the next save.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
