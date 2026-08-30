import Foundation

/// Measures the iCloud account.
///
/// Two sources, both public: `brctl quota` for the free space, and a walk of the
/// ubiquity container for iCloud Drive. Nothing here reads a private framework or
/// authenticates against Apple's web endpoints — the price of that is an
/// `Unmeasured` segment, which is the honest trade.
public struct ICloudStorageService: Sendable {

    private static let brctl = "/usr/bin/brctl"

    private let runner: ProcessRunner
    private let containerURL: URL

    public init(
        runner: ProcessRunner = ProcessRunner(),
        containerURL: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    ) {
        self.runner = runner
        self.containerURL = containerURL
    }

    /// - Parameter planBytes: the user's plan, when they have told us. Inferred when
    ///   nil, because macOS exposes no API for it.
    public func storage(planBytes: Int64? = nil) async throws -> ICloudStorage {
        let free = try await freeBytes()
        let drive = measureDrive()
        let total = planBytes ?? Self.inferPlan(freeBytes: free)

        return ICloudStorage(
            totalBytes: total,
            freeBytes: free,
            documentsBytes: drive.inCloud,
            documentsOnDiskBytes: drive.onDisk,
            planWasInferred: planBytes == nil,
            unreadableCount: drive.unreadable
        )
    }

    /// Whether iCloud Drive is signed in at all. `brctl` fails when it is not.
    public func isAvailable() async -> Bool {
        (try? await freeBytes()) != nil
    }

    // MARK: - Quota

    private func freeBytes() async throws -> Int64 {
        let data = try await runner.run(Self.brctl, ["quota"], timeout: .seconds(15))
        guard let text = String(data: data, encoding: .utf8),
              let bytes = Self.parseQuota(text)
        else { throw ProcessError.failed(command: "brctl quota", status: 0, stderr: "unparsable") }
        return bytes
    }

    /// `brctl quota` prints one line: "158671798507 bytes of quota remaining in
    /// personal account". Only the leading integer is contractual, so only that is
    /// relied on.
    static func parseQuota(_ output: String) -> Int64? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: " ").first, let bytes = Int64(first),
              bytes >= 0
        else { return nil }
        return bytes
    }

    // MARK: - Plan size

    /// Apple's tiers, in binary gigabytes.
    ///
    /// Binary, not decimal: measured against a real account, `brctl` reported
    /// 158,671,798,507 bytes free where iCloud's own web page said "Free 147.8 GB"
    /// and "200 GB" — 147.8 GiB and 200 GiB exactly. Apple labels GiB as GB here.
    static let planTiers: [Int64] = [5, 50, 200, 2048, 6144, 12288].map { $0 * 1024 * 1024 * 1024 }

    /// The smallest plan that could hold this much free space.
    ///
    /// A guess, and the only one available: no public API reports the plan. It is
    /// right whenever the account is less than half empty, and wrong only for a large
    /// plan that is almost entirely full — which is why the result is marked
    /// `planWasInferred` and can be overridden in Preferences.
    static func inferPlan(freeBytes: Int64) -> Int64 {
        planTiers.first { $0 >= freeBytes } ?? planTiers[planTiers.count - 1]
    }

    // MARK: - iCloud Drive

    private struct DriveMeasurement {
        var inCloud: Int64 = 0
        var onDisk: Int64 = 0
        var unreadable = 0
    }

    /// Walks the ubiquity container.
    ///
    /// Counts logical size, not allocated: an evicted file occupies no blocks here
    /// but still occupies the account's quota, and the quota is what this card is
    /// about. Measured live, one account held 6.08 GB in iCloud Drive of which only
    /// 105 MB was on the Mac — a gap invisible to any `du`-style measurement.
    private func measureDrive() -> DriveMeasurement {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey
        ]
        var measurement = DriveMeasurement()

        guard let enumerator = FileManager.default.enumerator(
            at: containerURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                measurement.unreadable += 1
                // One unreadable item costs one item, never the whole measurement.
                return true
            }
        ) else { return measurement }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else {
                measurement.unreadable += 1
                continue
            }
            guard values.isDirectory == false, values.isUbiquitousItem == true else { continue }
            measurement.inCloud += Int64(values.fileSize ?? 0)
            measurement.onDisk += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return measurement
    }
}
