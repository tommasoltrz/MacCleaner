import Foundation

/// Docker's own accounting of what a prune would free.
///
/// This is the one scanner that does not walk the filesystem, because it cannot:
/// dangling image layers, stopped containers, unused volumes and build cache all
/// live *inside* Docker Desktop's single VM disk image, where no per-file API can
/// tell one from another. `docker system df` is Docker reading its own ledger, so
/// running it is not a measurement of the disk — every byte the rest of the app
/// reports still comes from `context.measurer`.
///
/// The interesting path here is the unavailable one. Docker Desktop is not running
/// on most Macs most of the time, and the row has to say so in a way the user can
/// act on: the predecessor's bare "Docker is not running" left them with nothing to
/// do about it.
public struct DockerScanner: CategoryScanner {

    public let id: CategoryID = .docker

    private let runner: ProcessRunner
    private let timeout: Duration
    private let resolveExecutable: @Sendable () -> String?

    /// - Parameters:
    ///   - timeout: deliberately short. A daemon that is booting, or a VM that has
    ///     lost its socket, leaves the CLI blocked indefinitely; a healthy
    ///     `system df` answers in well under a second. One category must never hold
    ///     the whole scan hostage, so the wait is capped and a lapsed one reads as
    ///     "not running" rather than as a thrown error.
    ///   - resolveExecutable: injectable so the unavailable paths can be tested
    ///     without Docker installed.
    public init(
        runner: ProcessRunner = ProcessRunner(),
        timeout: Duration = .seconds(5),
        resolveExecutable: @escaping @Sendable () -> String? = { SystemExecutable.resolveDocker() }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.resolveExecutable = resolveExecutable
    }

    // MARK: - User-facing copy

    /// Verbatim from the design. The row renders disabled with an `unavailable`
    /// badge, and this subtitle is the only thing telling the user how to fix it.
    static let daemonReason =
        "Docker Desktop is not running. Start it to measure images and volumes."

    /// A different string from `daemonReason` on purpose: "start it" is useless
    /// advice to someone who has no Docker to start.
    static let notInstalledReason =
        "Docker Desktop is not installed. There is nothing to measure on this Mac."

    /// Docker Desktop keeps its VM disk here. Only consulted to honour an exclusion
    /// rule — never measured, never listed.
    static let dataDirectory = NSHomeDirectory() + "/Library/Containers/com.docker.docker"

    private static let arguments = ["system", "df", "--format", "{{json .}}"]

    // MARK: - Scanning

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        try Task.checkCancellation()

        // Never `docker` off `PATH`: a GUI app launched from Finder inherits none of
        // the shell's environment, so name resolution works in a dev terminal and
        // then silently reports "not installed" to every real user.
        guard let executable = resolveExecutable() else {
            return .unavailable(id, reason: Self.notInstalledReason)
        }

        // Pruning frees space inside Docker's container folder, so a user who has
        // excluded that folder has already said to leave it alone.
        if context.isWithinExclusion(URL(fileURLWithPath: Self.dataDirectory)) {
            return ScanCategoryResult(categoryID: id, availability: .empty)
        }

        let output: Data
        do {
            output = try await runner.run(executable, Self.arguments, timeout: timeout)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as ProcessError {
            return .unavailable(id, reason: Self.reason(for: error))
        } catch {
            // `Process.run()` itself failed — the binary vanished, or is quarantined
            // or non-executable. Nothing about the daemon can be concluded.
            return .unavailable(id, reason: Self.notInstalledReason)
        }

        try Task.checkCancellation()

        let usage = Self.parseDiskUsage(output)
        var unreadableCount = usage.unreadableLines
        var entries: [FileEntry] = []

        for row in usage.rows where row.reclaimableBytes > 0 {
            if let entry = Self.entry(for: row) {
                entries.append(entry)
            } else {
                unreadableCount += 1
            }
        }

        entries.sort { $0.allocatedBytes > $1.allocatedBytes }
        let total = entries.reduce(Int64(0)) { $0 + $1.allocatedBytes }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: total,
            entries: entries,
            // A running daemon with nothing to prune is `.empty`, not `.unavailable`:
            // the row is disabled either way, but only one of them asks the user to
            // go start something that is already started.
            availability: entries.isEmpty ? .empty : .available,
            unreadableCount: unreadableCount
        )
    }

    static func reason(for error: ProcessError) -> String {
        switch error {
        case .executableMissing:
            return notInstalledReason
        case .timedOut, .failed:
            // `system df` exits non-zero with "Cannot connect to the Docker daemon"
            // when Docker Desktop is stopped, and is killed by the watchdog when it
            // is wedged. Both are the same state to the user: unusable until started.
            return daemonReason
        }
    }

    // MARK: - Entries

    private static func entry(for row: DiskUsageRow) -> FileEntry? {
        guard let url = identityURL(for: row.type) else { return nil }
        // Build cache is the only row that unambiguously rebuilds itself; images and
        // volumes can hold the only copy of something.
        let isBuildCache = row.type.range(of: "build cache", options: .caseInsensitive) != nil
        return FileEntry(
            url: url,
            displayName: row.type,
            parentDisplay: "Docker Desktop",
            // Every one of these bytes is space inside Docker's VM disk image, which
            // is what the row is offering to give back.
            kind: isBuildCache ? .cache : .diskImage,
            allocatedBytes: row.reclaimableBytes,
            // `docker system df` carries no last-used date without `-v`, which is a
            // far more expensive call. The column stays empty rather than guessing.
            lastOpened: nil,
            isRegenerable: isBuildCache,
            // Nothing here is a path this app can trash: every byte lives inside
            // Docker's VM disk image, and only Docker can give it back. The row
            // therefore hands over the exact command, like a simulator runtime does,
            // instead of a checkbox that would fail on confirm.
            manualRemoval: FileEntry.ManualRemoval(
                explanation: "This space lives inside Docker Desktop's disk image, "
                    + "and only Docker can release it.",
                command: pruneCommand(for: row.type)
            )
        )
    }

    /// Identity for a ledger row.
    ///
    /// Deliberately not a file URL. These rows are not paths and cannot be removed
    /// by unlinking anything — only `docker system prune` frees them — so a
    /// plausible-looking path here would be an invitation for a file-based remover
    /// to act on one by mistake.
    /// Docker's own prune command for one `system df` row.
    static func pruneCommand(for type: String) -> String {
        let lowered = type.lowercased()
        if lowered.contains("build") { return "docker builder prune" }
        if lowered.contains("image") { return "docker image prune -a" }
        if lowered.contains("container") { return "docker container prune" }
        if lowered.contains("volume") { return "docker volume prune" }
        return "docker system prune"
    }

    static func identityURL(for type: String) -> URL? {
        let slug = String(type.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
        return URL(string: "docker://reclaimable/\(slug)")
    }

    // MARK: - Pure parsing (fixture-testable)

    struct DiskUsageRow: Sendable, Equatable {
        /// Docker's own label: `Images`, `Containers`, `Local Volumes`, `Build Cache`.
        var type: String
        var reclaimableBytes: Int64
    }

    struct DiskUsage: Sendable, Equatable {
        var rows: [DiskUsageRow]
        /// Lines that could not be decoded. The Electron version turned these into a
        /// zero-byte "Unknown" row, which quietly understated the total; here they
        /// surface through `unreadableCount` instead.
        var unreadableLines: Int
    }

    private struct DiskUsageLine: Decodable {
        var type: String?
        var reclaimable: String?

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case reclaimable = "Reclaimable"
        }
    }

    /// `--format "{{json .}}"` emits one JSON object per line, not an array — and
    /// the Go template form works on CLI versions predating `--format json`.
    static func parseDiskUsage(_ data: Data) -> DiskUsage {
        let decoder = JSONDecoder()
        var rows: [DiskUsageRow] = []
        var unreadable = 0

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let decoded = try? decoder.decode(DiskUsageLine.self, from: Data(trimmed.utf8)),
                  let type = decoded.type, !type.isEmpty,
                  let bytes = parseSize(decoded.reclaimable ?? "0")
            else {
                unreadable += 1
                continue
            }
            rows.append(DiskUsageRow(type: type, reclaimableBytes: bytes))
        }
        return DiskUsage(rows: rows, unreadableLines: unreadable)
    }

    /// Parses a size as Docker prints it: `0B`, `1.097kB`, `12.9GB`, and for a
    /// reclaimable column `8.135GB (63%)` — the trailing percentage is ignored.
    ///
    /// Docker formats with go-units `HumanSize`, which is **decimal**: `GB` means
    /// 10⁹. The Electron original multiplied every unit by a power of 1024 and so
    /// over-reported Docker totals by ~7% at GB scale. Binary suffixes (`GiB`) are
    /// accepted too, since some Docker output uses `BytesSize` instead.
    static func parseSize(_ text: String) -> Int64? {
        var index = text.startIndex
        while index < text.endIndex, !text[index].isNumber {
            index = text.index(after: index)
        }

        var digits = ""
        while index < text.endIndex, text[index].isNumber || text[index] == "." {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard let value = Double(digits) else { return nil }

        while index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }
        var unit = ""
        while index < text.endIndex, text[index].isLetter, unit.count < 3 {
            unit.append(text[index])
            index = text.index(after: index)
        }

        guard let multiplier = multiplier(for: unit) else { return nil }
        // A garbled number must not trap the whole scan on an Int64 conversion.
        let bytes = (value * multiplier).rounded()
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    private static func multiplier(for unit: String) -> Double? {
        guard !unit.isEmpty else { return 1 }
        let normalized = unit.uppercased()
        guard let prefix = normalized.first else { return nil }
        let base: Double = normalized.contains("I") ? 1024 : 1000

        switch prefix {
        case "B": return normalized.count == 1 ? 1 : nil
        case "K": return base
        case "M": return pow(base, 2)
        case "G": return pow(base, 3)
        case "T": return pow(base, 4)
        case "P": return pow(base, 5)
        default:  return nil
        }
    }
}
