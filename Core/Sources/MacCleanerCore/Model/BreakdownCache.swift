import Foundation

/// The last measured breakdown, persisted between launches.
///
/// Without this the Dashboard measured the whole home directory on every launch,
/// which meant every launch also walked `~/Documents`, `~/Desktop` and `~/Downloads`
/// — the three folders macOS gates behind TCC. On an unsigned development build the
/// signature changes with each rebuild, so the system re-asks for permission every
/// single time.
///
/// Showing the last known figures immediately and measuring only on request fixes
/// that, and is better behaviour regardless: a disk utility should not hammer the
/// disk merely because you opened it. The design anticipates this — Preferences ›
/// Advanced offers "Rebuild the size index", which only makes sense if an index is
/// being kept.
public struct BreakdownCache: Codable, Sendable {
    public var volume: VolumeInfo
    public var breakdown: StorageBreakdown
    public var measuredAt: Date

    public init(volume: VolumeInfo, breakdown: StorageBreakdown, measuredAt: Date) {
        self.volume = volume
        self.breakdown = breakdown
        self.measuredAt = measuredAt
    }

    /// Figures older than this are shown but marked stale.
    public static let freshnessWindow: TimeInterval = 24 * 60 * 60

    public var isStale: Bool {
        Date().timeIntervalSince(measuredAt) > Self.freshnessWindow
    }

    // MARK: - Storage

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MacCleaner", isDirectory: true)
            .appendingPathComponent("breakdown-cache.json")
    }

    public static func load() -> BreakdownCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BreakdownCache.self, from: data)
    }

    public func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
