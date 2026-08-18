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

    /// The Dashboard's "Safe to remove" tile: caches and package tarballs that
    /// regenerate on demand, cleanable without human judgement.
    public var safeToRemoveBytes: Int64 {
        categories.filter { $0.categoryID.isSafe }.reduce(0) { $0 + $1.totalBytes }
    }

    /// The "Needs review" tile: large files and unused apps — the user decides.
    public var needsReviewBytes: Int64 {
        categories.filter { !$0.categoryID.isSafe }.reduce(0) { $0 + $1.totalBytes }
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

    /// The seven categories the design specifies, in its listed order.
    ///
    /// Order matters only for presentation — the scanners run concurrently.
    public static func standard() -> ScanCoordinator {
        ScanCoordinator(scanners: [
            DocumentsFilesScanner(),
            ApplicationsScanner(),
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
                        // One failing category must not lose the whole scan. It is
                        // reported as unavailable, with the reason shown in its row.
                        return .unavailable(scanner.id, reason: Self.describe(error))
                    }
                }
            }

            for try await raw in group {
                // Applied centrally so all seven scanners share one definition of
                // "too small to bother the user with".
                let result = raw.filteringNoise(below: Self.entryNoiseFloor)
                results.append(result)
                onCategory?(result)
                let weight = weights[result.categoryID] ?? 1.0
                onProgress?(tracker.advance(by: weight))
            }
        }

        // Present in the design's fixed order, not completion order.
        let order = CategoryID.allCases
        results.sort {
            (order.firstIndex(of: $0.categoryID) ?? 0) < (order.firstIndex(of: $1.categoryID) ?? 0)
        }

        return ScanResults(categories: results, startedAt: startedAt, finishedAt: Date())
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
