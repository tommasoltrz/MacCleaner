import Foundation

/// Progress for the toolbar's `Measuring {n}%` readout.
public struct ScanProgress: Sendable, Equatable {
    /// 0...100, weighted so slow categories do not make the bar stall.
    public var percent: Int
    public var completedCategories: Int
    public var totalCategories: Int
}

/// Everything a finished scan produced.
public struct ScanResults: Sendable, Equatable {
    public var categories: [ScanCategoryResult]
    public var startedAt: Date
    public var finishedAt: Date

    /// Public so views can build sample results for SwiftUI previews without
    /// running a real scan against the user's disk.
    public init(categories: [ScanCategoryResult], startedAt: Date, finishedAt: Date) {
        self.categories = categories
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var totalBytes: Int64 {
        categories.reduce(0) { $0 + $1.totalBytes }
    }

    /// The Dashboard's "Safe to Remove" tile. It includes cache data that
    /// regenerates and application leftovers that have no installed owner.
    ///
    /// Judged per entry, not per category. A safe category can still hold the one
    /// thing that does not come back — an `.xcarchive` with a shipped build's only
    /// dSYMs — and the tile's promise, "removal loses nothing", has to hold for
    /// every row it counts.
    public var safeToRemoveBytes: Int64 {
        categories.reduce(0) { $0 + $1.safeToRemoveBytes }
    }

    /// The "Needs review" tile: large files, unused apps, and anything in a safe
    /// category that does not regenerate — the user decides.
    public var needsReviewBytes: Int64 {
        categories.reduce(0) { $0 + $1.needsReviewBytes }
    }

    /// Categories with something to show, in the design's fixed order.
    public var actionableCategories: [ScanCategoryResult] {
        categories.filter { $0.availability.isActionable && $0.totalBytes > 0 }
    }
}

/// Runs the category scanners.
///
/// An actor because re-entrancy has to be impossible: the design triggers a scan
/// from three places (toolbar button, Dashboard status bar, Scan menu) and requires
/// that "a scan already running ignores further triggers".
public actor ScanCoordinator {

    /// Relative cost, so the progress bar advances at a believable rate. Applications
    /// is by far the slowest — it measures every bundle plus its scattered leftovers.
    private static let weights: [CategoryID: Double] = [
        .documentsAndFiles: 3.0,
        .applications: 4.0,
        .applicationLeftovers: 1.0,
        .hiddenSystemData: 2.0,
        .systemCaches: 1.0,
        .packageManagers: 1.0,
        .xcode: 1.0,
        .docker: 0.5
    ]

    /// Entries below this never reach the UI. A live scan surfaced a 0.2 MB app
    /// helper rendered as "0.0 MB" — a row that costs attention and returns nothing.
    private static let entryNoiseFloor: Int64 = 1024 * 1024

    private let scanners: [any CategoryScanner]
    private var runningTask: Task<ScanResults, Error>?

    public init(scanners: [any CategoryScanner]) {
        self.scanners = scanners
    }

    /// Standard categories in display order. Scanners run concurrently.
    public static func standard() -> ScanCoordinator {
        ScanCoordinator(scanners: [
            DocumentsFilesScanner(),
            ApplicationsScanner(),
            ApplicationLeftoversScanner(),
            HiddenDataScanner(),
            SystemCachesScanner(),
            PackageManagerScanner(),
            XcodeScanner(),
            DockerScanner()
        ])
    }

    public var isScanning: Bool { runningTask != nil }

    /// Starts a scan, or returns the one already in flight.
    ///
    /// - Parameters:
    ///   - enabled: categories switched on in Preferences. A disabled category is
    ///     never measured — the design is explicit that "off" means *not measured*,
    ///     not *deleted*.
    ///   - onProgress: weighted 0...100 for the toolbar.
    ///   - onCategory: fired as each category finishes so its row fills in
    ///     incrementally rather than everything appearing at the end.
    public func scan(
        enabled: Set<CategoryID>? = nil,
        context: ScanContext = ScanContext(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        onCategory: (@Sendable (ScanCategoryResult) -> Void)? = nil
    ) async throws -> ScanResults {
        if let runningTask { return try await runningTask.value }

        let active = scanners.filter { enabled?.contains($0.id) ?? true }
        let task = Task { [active] in
            try await Self.run(
                active,
                context: context,
                onProgress: onProgress,
                onCategory: onCategory
            )
        }
        runningTask = task
        defer { runningTask = nil }
        return try await task.value
    }

    /// Cancels an in-flight scan. Measurement checks cancellation periodically, so
    /// this returns promptly rather than at the end of the current category.
    public func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    private static func run(
        _ scanners: [any CategoryScanner],
        context: ScanContext,
        onProgress: (@Sendable (ScanProgress) -> Void)?,
        onCategory: (@Sendable (ScanCategoryResult) -> Void)?
    ) async throws -> ScanResults {
        let startedAt = Date()
        let totalWeight = scanners.reduce(0.0) { $0 + (weights[$1.id] ?? 1.0) }
        let tracker = ProgressTracker(totalWeight: totalWeight, totalCategories: scanners.count)

        var results: [ScanCategoryResult] = []

        try await withThrowingTaskGroup(of: ScanCategoryResult.self) { group in
            for scanner in scanners {
                group.addTask {
                    do {
                        return try await scanner.scan(context: context)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One category failure must not lose the whole scan. The row
                        // reports that category as unavailable and gives the reason.
                        return .unavailable(scanner.id, reason: Self.describe(error))
                    }
                }
            }

            for try await raw in group {
                // Apply this centrally so all scanners share one definition of
                // "too small to bother the user with".
                let result = raw.filteringNoise(below: Self.entryNoiseFloor)
                results.append(result)
                onCategory?(result)
                let weight = weights[result.categoryID] ?? 1.0
                onProgress?(tracker.advance(by: weight))
            }
        }

        // An exact application-leftover group owns its paths. Remove each
        // overlapping generic row before the user can select the same path through
        // a cleanup route that does not repeat the owner and identity checks. If a
        // generic row contains a leftover path, remove the full row. Keeping that
        // parent would also remove the protected child when cleanup removes it.
        results = removingApplicationLeftoverOverlaps(from: results)

        // Present in the design's fixed order, not completion order.
        let order = CategoryID.allCases
        results.sort {
            (order.firstIndex(of: $0.categoryID) ?? 0) < (order.firstIndex(of: $1.categoryID) ?? 0)
        }

        return ScanResults(categories: results, startedAt: startedAt, finishedAt: Date())
    }

    static func removingApplicationLeftoverOverlaps(
        from results: [ScanCategoryResult]
    ) -> [ScanCategoryResult] {
        let leftoverPaths = results
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .entries
            .flatMap(\.children)
            .map { $0.url.standardizedFileURL.path } ?? []
        guard !leftoverPaths.isEmpty else { return results }

        func overlapsLeftover(_ entry: FileEntry) -> Bool {
            let path = entry.url.standardizedFileURL.path
            return leftoverPaths.contains { leftover in
                path == leftover
                    || path.hasPrefix(leftover + "/")
                    || leftover.hasPrefix(path + "/")
            }
        }

        return results.map { result in
            guard result.categoryID != .applicationLeftovers,
                  !result.entries.isEmpty
            else { return result }

            var copy = result
            copy.entries = result.entries.compactMap { original in
                guard !overlapsLeftover(original) else { return nil }
                var entry = original
                entry.children.removeAll(where: overlapsLeftover)
                return entry
            }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            if copy.entries.isEmpty, copy.availability == .available {
                copy.availability = .empty
            }
            return copy
        }
    }

    private static func describe(_ error: Error) -> String {
        if let processError = error as? ProcessError {
            switch processError {
            case .executableMissing(let path):
                return "Required tool not found at \(path)."
            case .timedOut:
                return "Timed out while measuring. Try again."
            case .failed:
                return "Could not be measured."
            }
        }
        return "Could not be measured."
    }
}

/// Accumulates weighted progress across concurrently finishing categories.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalWeight: Double
    private let totalCategories: Int
    private var completedWeight = 0.0
    private var completedCategories = 0

    init(totalWeight: Double, totalCategories: Int) {
        self.totalWeight = max(totalWeight, 0.001)
        self.totalCategories = totalCategories
    }

    func advance(by weight: Double) -> ScanProgress {
        lock.lock()
        defer { lock.unlock() }
        completedWeight += weight
        completedCategories += 1
        return ScanProgress(
            percent: min(100, Int((completedWeight / totalWeight) * 100)),
            completedCategories: completedCategories,
            totalCategories: totalCategories
        )
    }
}
