import Foundation

/// What happened to a removed item.
///
/// Recorded rather than inferred because it decides whether the bytes are still
/// recoverable: only a `trashed` item still exists somewhere on disk.
public enum RemovalDisposition: String, Sendable, CaseIterable {
    case trashed
    case deleted
    /// A Put Back consumed the matching `trashed` record. Appended as a tombstone
    /// (the log is append-only), so the Trash path it names cannot match a later,
    /// unrelated occupant of the same path.
    case restored
}

/// One logged removal.
public struct RemovalRecord: Sendable, Equatable {
    public var timestamp: Date
    /// Where the item lived before removal — for a `trashed` item this is also the
    /// destination a Put Back restores to.
    public var originalPath: String
    public var bytes: Int64
    public var disposition: RemovalDisposition
    /// Where a `trashed` item actually landed, as reported by `trashItem` — the
    /// Trash renames on collision, so the basename alone identifies nothing. Put
    /// Back matches on this, never on the name: a filename match once offered to
    /// restore an unrelated, Finder-trashed `Report.pdf` to an old record's folder.
    /// `nil` for permanent deletions and for privileged moves, which do not report
    /// their destination.
    public var trashedPath: String?
    /// The trashed file's `device:inode`, which is what actually identifies it.
    /// A path is a location, not an identity: once the item leaves the Trash the
    /// same path can be handed to an unrelated file, and Put Back would then
    /// restore a stranger to this record's folder. `nil` on records written before
    /// this field existed, which fall back to the timestamp window.
    public var trashedIdentity: String?

    public init(
        timestamp: Date,
        originalPath: String,
        bytes: Int64,
        disposition: RemovalDisposition,
        trashedPath: String? = nil,
        trashedIdentity: String? = nil
    ) {
        self.timestamp = timestamp
        self.originalPath = originalPath
        self.bytes = bytes
        self.disposition = disposition
        self.trashedPath = trashedPath
        self.trashedIdentity = trashedIdentity
    }
}

/// `device:inode` for a path, the pair the filesystem uses to tell files apart.
///
/// Read through `lstat`, deliberately: `stat` follows a symlink and would identify
/// its *target*, so a trashed link would be indistinguishable from a replacement
/// link pointing at the same place — and a broken link, whose target does not
/// exist, would have no identity at all. `lstat` identifies the link itself.
///
/// Read through the filesystem rather than `URLResourceValues.fileResourceIdentifier`,
/// which is an opaque object that cannot be written to a log and compared later.
public enum FileIdentity {
    public static func of(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(Int64(info.st_dev)):\(UInt64(info.st_ino))"
    }
}

public enum RemovalLogError: Error, Equatable {
    case unwritable(String)
}

/// The append-only record of everything MacCleaner has removed, at
/// `~/Library/Logs/MacCleaner/removals.log`.
///
/// It answers "what did this app do to my disk?" in a file the user can read, tail
/// and keep after the app is gone — which is why it is line-oriented text rather
/// than a JSON document: a structured document has to be rewritten whole on every
/// append, so an interrupted write loses the entire history instead of one line.
///
/// It is also load-bearing. macOS exposes no public API for a trashed item's
/// original location, so this log is the *only* thing that makes ``TrashService``'s
/// Put Back possible — see the policy note there. That makes the format a contract:
/// a line that cannot be parsed back is a Put Back the user silently loses, so paths
/// are quoted and escaped rather than merely separated.
///
/// ```
/// 2026-08-18T09:41:07Z "/Users/me/Downloads/My Big File (2).zip" 41231360 trashed
/// ```
///
/// The timestamp, byte count and disposition contain no spaces, so only the path
/// needs quoting. Backslash, quote, newline and carriage return are escaped inside
/// it — the newline escapes are what keep "one line per removal" true for the file
/// names macOS actually allows.
public struct RemovalLog: Sendable {

    /// Injectable so tests — and anything else that must not touch the user's real
    /// history — can point at a directory of their own.
    public let directory: URL

    public init(directory: URL = RemovalLog.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacCleaner", isDirectory: true)
    }

    public var logFileURL: URL {
        directory.appendingPathComponent("removals.log")
    }

    // MARK: - Writing

    /// Records entries that have just been removed.
    ///
    /// Only `url` and `allocatedBytes` are read: an app bundle's `children` are
    /// removed — and therefore logged — as entries in their own right, so following
    /// them here would double every leftover.
    public func append(
        entries: [FileEntry],
        disposition: RemovalDisposition,
        at timestamp: Date = Date()
    ) throws {
        try append(entries.map {
            RemovalRecord(
                timestamp: timestamp,
                originalPath: $0.url.path,
                bytes: $0.allocatedBytes,
                disposition: disposition
            )
        })
    }

    public func append(_ records: [RemovalRecord]) throws {
        guard !records.isEmpty else { return }
        let url = logFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // `O_APPEND` rather than seek-then-write: the kernel places each write at the
        // current end of the file, so a second MacCleaner process — or the same one
        // logging from two removals — cannot land a line on top of another's.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw RemovalLogError.unwritable(url.path) }
        defer { close(descriptor) }

        let text = records.map(Self.line(for:)).joined(separator: "\n") + "\n"
        try Data(text.utf8).withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = write(descriptor, base.advanced(by: written), buffer.count - written)
                guard count > 0 else { throw RemovalLogError.unwritable(url.path) }
                written += count
            }
        }
    }

    // MARK: - Reading

    /// The most recent removals, newest first.
    ///
    /// Unparseable lines are skipped rather than aborting the read: a truncated last
    /// line from a power cut must not cost the user the Put Back history above it.
    public func recentEntries(limit: Int = 200) -> [RemovalRecord] {
        guard limit > 0, let data = try? Data(contentsOf: logFileURL) else { return [] }
        let text = String(decoding: data, as: UTF8.self)

        var records: [RemovalRecord] = []
        // Walked backwards so `limit` bounds the parsing too, not just the result.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let record = Self.record(from: line) else { continue }
            records.append(record)
            if records.count == limit { break }
        }
        return records
    }

    // MARK: - Line format

    private static let timestampStyle = Date.ISO8601FormatStyle()

    /// `<timestamp> "<original>" <bytes> <disposition> ["<trash path>" [dev:ino]]`
    /// — the trailing fields are optional, so older lines still parse.
    static func line(for record: RemovalRecord) -> String {
        let timestamp = record.timestamp.formatted(timestampStyle)
        let path = quote(record.originalPath)
        var line = "\(timestamp) \(path) \(record.bytes) \(record.disposition.rawValue)"
        if let trashed = record.trashedPath {
            line += " " + quote(trashed)
            if let identity = record.trashedIdentity { line += " " + identity }
        }
        return line
    }

    static func record(from line: Substring) -> RemovalRecord? {
        guard let firstSpace = line.firstIndex(of: " ") else { return nil }
        let stamp = String(line[..<firstSpace])
        guard let (path, tail) = unquote(line[line.index(after: firstSpace)...]) else { return nil }

        // Two bare fields, then optionally one more quoted path.
        let fields = tail.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let bytes = Int64(fields[0]),
              let disposition = RemovalDisposition(rawValue: String(fields[1])),
              let timestamp = try? timestampStyle.parse(stamp)
        else { return nil }
        var trashedPath: String?
        var trashedIdentity: String?
        if fields.count == 3, let (trashed, rest) = unquote(fields[2]) {
            trashedPath = trashed
            let tail = rest.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { trashedIdentity = tail }
        }

        return RemovalRecord(
            timestamp: timestamp,
            originalPath: path,
            bytes: bytes,
            disposition: disposition,
            trashedPath: trashedPath,
            trashedIdentity: trashedIdentity
        )
    }

    private static func quote(_ path: String) -> String {
        var quoted = "\""
        for character in path {
            switch character {
            case "\\":   quoted += "\\\\"
            case "\"":   quoted += "\\\""
            case "\n":   quoted += "\\n"
            case "\r":   quoted += "\\r"
            default:     quoted.append(character)
            }
        }
        return quoted + "\""
    }

    /// Reads one quoted path, returning it alongside whatever follows the closing
    /// quote. `nil` for anything that is not a properly terminated quoted field.
    private static func unquote(_ input: Substring) -> (String, Substring)? {
        guard input.first == "\"" else { return nil }
        var value = ""
        var index = input.index(after: input.startIndex)

        while index < input.endIndex {
            let character = input[index]
            if character == "\\" {
                let escaped = input.index(after: index)
                guard escaped < input.endIndex else { return nil }
                switch input[escaped] {
                case "n":            value.append("\n")
                case "r":            value.append("\r")
                case let literal:    value.append(literal)
                }
                index = input.index(after: escaped)
                continue
            }
            if character == "\"" {
                return (value, input[input.index(after: index)...])
            }
            value.append(character)
            index = input.index(after: index)
        }
        return nil
    }
}
