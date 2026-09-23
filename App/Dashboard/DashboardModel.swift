import Foundation
import Observation
import ScoloCore

/// Owns storage measurements, snapshots, and storage history.
@MainActor
@Observable
final class DashboardModel {
    @ObservationIgnored private let settings: SettingsStore?

    init(settings: SettingsStore? = nil) { self.settings = settings }

    private(set) var volume: VolumeInfo?

    private(set) var breakdown: StorageBreakdown?

    private(set) var snapshots: [SnapshotInfo] = []

    private(set) var isLoadingBreakdown = false

    private(set) var hasCompletedInitialDashboardLoad = false

    var isDashboardLoading: Bool {
        !hasCompletedInitialDashboardLoad || isLoadingBreakdown
    }

    var snapshotsExpanded = false

    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }

    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }

    private let iCloudService = ICloudStorageService()

    private(set) var iCloudStorage: ICloudStorage?

    var iCloudPlanBytes: Int64?

    func loadICloud() async {
        iCloudStorage = try? await iCloudService.storage(planBytes: iCloudPlanBytes)
    }

    private let diskInfo = DiskInfoService()

    private let snapshotService = SnapshotService()

    private let breakdownService = StorageBreakdownService()

    @ObservationIgnored private lazy var lowDiskNotifications = LowDiskNotificationService()

    @ObservationIgnored private var needsPostCleanupMeasurement = false

    private(set) var measuredAt: Date?

    var breakdownIsStale: Bool {
        guard let measuredAt else { return true }
        return Date().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }

    func loadDashboard() async {
        // A recreated main window runs this task again. Treat that refresh like the
        // first one too, rather than briefly presenting cached values as final.
        hasCompletedInitialDashboardLoad = false
        defer { hasCompletedInitialDashboardLoad = true }

        if let cached = BreakdownCache.load() {
            volume = cached.volume
            breakdown = cached.breakdown
            measuredAt = cached.measuredAt
        }

        // Snapshot listing touches no user files and is safe on every launch.
        // `measureStorage` refreshes volume totals and checks the low-space threshold.
        snapshots = (try? await snapshotService.listAll()) ?? []

        // The growth report is dated history, so the one the previous session left
        // is already true. Reading it first puts it on screen at once instead of
        // leaving the card blank for the length of a disk walk.
        await loadStorageHistory()

        await measureStorage(trigger: .launch)
    }

    func measureStorage(trigger: SnapshotTrigger = .manual) async {
        guard !isLoadingBreakdown else {
            if trigger == .removal { needsPostCleanupMeasurement = true }
            return
        }
        isLoadingBreakdown = true
        let presentation = OperationPresentationDuration()
        defer {
            isLoadingBreakdown = false
            if needsPostCleanupMeasurement {
                needsPostCleanupMeasurement = false
                Task { await measureStorage(trigger: .removal) }
            }
        }

        // iCloud rides along with every measurement, so the account card stays in
        // step with the main card. Cheap enough to piggyback: one `brctl` call and
        // a walk of the ubiquity container, where evicted files are stubs on disk.
        Task { await self.loadICloud() }

        // `diskutil info` is cheap and not TCC-gated. Refreshing here keeps the menu
        // bar, Dashboard warning and system notification in step after cleanup too.
        await refreshVolumeInfo()

        // `measure` rather than `breakdown`: the same single walk, with the folder
        // tables it produced kept instead of thrown away. The growth report reads
        // those, and a second traversal to collect them would double the cost of
        // the most expensive measurement in the app.
        guard let measured = try? await breakdownService.measure() else {
            try? await presentation.wait()
            return
        }
        breakdown = measured.breakdown

        // The walk takes time. Read the volatile volume figures again, then put
        // Available, Free, and the sidebar on this one completed snapshot.
        await refreshVolumeInfo()
        measuredAt = Date()

        if let volume, let breakdown {
            BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: Date()).save()
        }

        await recordSnapshot(of: measured, trigger: trigger)
        try? await presentation.wait()
    }

    private let snapshotStore = StorageSnapshotStore()

    @ObservationIgnored private var storageHistory: [StorageSnapshot] = []

    private(set) var growth: GrowthComparison?

    private(set) var hasCleanupGrowthBaseline = false

    private var preferredGrowthBaseline: GrowthBaseline? = UserDefaults.standard.string(forKey: "growthBaseline")
        .flatMap(GrowthBaseline.init(rawValue:))
        .flatMap { $0 == .previousMeasurement ? nil : $0 }

    var growthBaseline: GrowthBaseline {
        get {
            preferredGrowthBaseline == .sevenDays || !hasCleanupGrowthBaseline
                ? .sevenDays : .lastCleanup
        }
        set {
            guard newValue != .previousMeasurement else { return }
            preferredGrowthBaseline = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "growthBaseline")
            recomputeGrowth()
        }
    }

    private func loadStorageHistory() async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { store.load() }.value
        recomputeGrowth()
    }

    private func recordSnapshot(
        of measurement: StorageMeasurement,
        trigger: SnapshotTrigger
    ) async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { () -> [StorageSnapshot] in
            if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) {
                try? store.save(snapshot)
            }
            return store.load()
        }.value
        recomputeGrowth()
    }

    private func recomputeGrowth() {
        hasCleanupGrowthBaseline = storageHistory.contains { $0.trigger == .removal }
        growth = StorageGrowth.comparison(growthBaseline, in: storageHistory)
    }

    func clearMeasurementHistory() {
        try? snapshotStore.clear()
        storageHistory = []
        recomputeGrowth()
    }

    func refreshVolumeInfo() async {
        volume = (try? await diskInfo.volumeInfo()) ?? volume
        if let volume, let breakdown {
            self.breakdown = breakdown.reconcilingVolume(
                capacityBytes: volume.capacityBytes,
                freeBytes: volume.freeBytes
            )
        }
        guard let volume, let settings else { return }
        await lowDiskNotifications.observe(
            freeBytes: volume.freeBytes,
            volumeName: volume.name,
            thresholdGB: settings.warnBelowGB
        )
    }
}
