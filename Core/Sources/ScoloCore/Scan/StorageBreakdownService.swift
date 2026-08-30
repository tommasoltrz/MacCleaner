import Foundation

/// Computes the Dashboard's capacity card.
///
/// Ports the Electron `disk:breakdown` handler, with its two structural bugs fixed
/// rather than carried over:
///
/// * **Firmlink blindness.** `/System` reached through `/` is the read-only System
///   volume, but the Data volume carries its own `/System` tree — mainly
///   `System/Library/AssetsV2`, on-device Apple Intelligence models and Siri voices,
///   ~13 GB. Anything walking `/` misses it entirely, and it silently inflated the
///   unattributed remainder. It is measured at the Data volume's own mount point.
/// * **Double counting.** The predecessor put `~/Library/Caches` in "App Data" *and*
///   `~/Library/Caches/Homebrew` in "Package Caches", counting Homebrew twice and
///   quietly shrinking the residual. Roots here are disjoint by construction, and a
///   test asserts the segments sum to capacity.
public struct StorageBreakdownService: Sendable {

    private let diskInfo: DiskInfoService
    private let measurer: AllocatedSizeMeasurer

    public init(
        diskInfo: DiskInfoService = DiskInfoService(),
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer()
    ) {
        self.diskInfo = diskInfo
        self.measurer = measurer
    }

    // MARK: - Roots

    /// How many levels below `$HOME` the single walk records.
    ///
    /// Three is all the capacity card needs (`Library/Caches/Homebrew` is the
    /// deepest figure it reads). Four is what the growth report wants, so a change
    /// can be named as `Documents/Renewals/build` instead of as `Documents`. The
    /// extra level was measured on the user's Mac with `scolo-cli breakdown`
    /// before it was adopted; see the note in `CLAUDE.local.md`.
    public static let homeWalkDepth = 4

    /// Home-relative paths whose sizes are read out of the single walk.
    private enum HomePath {
        static let documents = ["Documents"]
        static let desktop = ["Desktop"]
        static let downloads = ["Downloads"]
        static let pictures = ["Pictures"]
        static let music = ["Music"]
        static let movies = ["Movies"]
        static let applications = ["Applications"]
        static let developer = ["Library", "Developer"]

        /// Disjoint from `packageCaches` — Homebrew's cache is subtracted below.
        static let appData: [[String]] = [
            ["Library", "Application Support"],
            ["Library", "Containers"],
            ["Library", "Group Containers"],
            ["Library", "Caches"],
            ["Library", "Preferences"]
        ]

        /// Regenerable toolchain caches. `Library/Caches/Homebrew` lives *inside*
        /// `Library/Caches`, so it is removed from the App Data total.
        static let packageCaches: [[String]] = [
            [".npm"], [".cache"], [".nvm"], [".gradle"], [".m2"],
            [".cargo"], [".rustup"], [".bun"], [".deno"],
            ["Library", "pnpm"],
            ["Library", "Caches", "Homebrew"]
        ]

        static let homebrewCache = ["Library", "Caches", "Homebrew"]
    }

    /// Machine-wide roots outside `$HOME` and `/Applications`.
    private static let systemDataRoots = [
        "/Library", "/private", "/opt", "/usr/local", "/Users/Shared"
    ]

    // MARK: - Computation

    /// The capacity card, and nothing else. Kept as the entry point for every caller
    /// that only needs the figures on screen.
    public func breakdown(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StorageBreakdown {
        try await measure(progress: progress).breakdown
    }

    /// One measurement of the whole disk, with the working figures kept.
    ///
    /// ``breakdown(progress:)`` throws away everything the walk learned except the
    /// twelve segment totals. The growth report needs the directories underneath
    /// them, and a second traversal to collect those would double the cost of the
    /// most expensive measurement in the app — about 20 s on the user's Mac. So the
    /// walk is paid for once and its results are handed out whole.
    public func measure(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StorageMeasurement {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL

        let volume = try await diskInfo.volumeInfo()
        let dataUsed = try await diskInfo.dataVolumeUsedBytes()
        progress?(0.05)

        // One traversal of $HOME supplies every home figure below, including
        // `Library/Caches/Homebrew`.
        let homeTree = try await measurer.measureSubtrees(of: home, depth: Self.homeWalkDepth)
        progress?(0.55)

        func homeBytes(_ components: [String]) -> Int64 {
            var url = home
            for component in components { url.appendPathComponent(component) }
            return homeTree[url.standardizedFileURL]?.allocatedBytes ?? 0
        }

        let homeTotal = homeTree[home.standardizedFileURL]?.allocatedBytes ?? 0
        let homeUnreadable = homeTree[home.standardizedFileURL]?.unreadableCount ?? 0

        // Machine-wide roots, each kept under its own URL so the growth report can
        // name the one that changed.
        var rootMeasurements: [URL: SizeMeasurement] = [:]

        // The Data volume's own /System tree, invisible to any walk of `/`.
        let dataSideSystemURL = URL(
            fileURLWithPath: DiskInfoService.dataVolumeMountPoint + "/System"
        ).standardizedFileURL
        let dataSideSystem = try await measurer.measure(dataSideSystemURL)
        rootMeasurements[dataSideSystemURL] = dataSideSystem
        progress?(0.7)

        var systemDataBytes: Int64 = 0
        var systemDataUnreadable = 0
        for root in Self.systemDataRoots {
            let url = URL(fileURLWithPath: root).standardizedFileURL
            let measured = try await measurer.measure(url)
            rootMeasurements[url] = measured
            systemDataBytes += measured.allocatedBytes
            systemDataUnreadable += measured.unreadableCount
        }
        progress?(0.9)

        let systemApplicationsURL = URL(fileURLWithPath: "/Applications").standardizedFileURL
        let systemApplications = try await measurer.measure(systemApplicationsURL)
        rootMeasurements[systemApplicationsURL] = systemApplications

        // Non-Data volumes: System, Preboot, Recovery, VM.
        let otherVolumes = max(0, volume.usedBytes - dataUsed)

        let documentsDesktop = homeBytes(HomePath.documents) + homeBytes(HomePath.desktop)
        let downloads = homeBytes(HomePath.downloads)
        let photos = homeBytes(HomePath.pictures)
        let music = homeBytes(HomePath.music)
        let movies = homeBytes(HomePath.movies)
        let developer = homeBytes(HomePath.developer)
        let homeApplications = homeBytes(HomePath.applications)

        let packageCaches = HomePath.packageCaches.reduce(Int64(0)) { $0 + homeBytes($1) }
        // Subtract the nested Homebrew cache so App Data and Package Caches stay
        // disjoint; without this Homebrew is counted in both.
        let appData = HomePath.appData.reduce(Int64(0)) { $0 + homeBytes($1) }
            - homeBytes(HomePath.homebrewCache)

        let accountedInHome = documentsDesktop + downloads + photos + music + movies
            + developer + homeApplications + packageCaches + appData
        let otherFilesInHome = max(0, homeTotal - accountedInHome)

        var raw: [StorageSegmentID: Int64] = [
            .macOSSystem: otherVolumes + dataSideSystem.allocatedBytes,
            .systemData: systemDataBytes,
            .documentsDesktop: documentsDesktop,
            .downloads: downloads,
            .photos: photos,
            .music: music,
            .movies: movies,
            .developer: developer,
            .appDataCaches: appData,
            .packageBuildCaches: packageCaches,
            .otherFilesInHome: otherFilesInHome,
            .applications: systemApplications.allocatedBytes + homeApplications
        ]

        // Everything no unprivileged scan could reach: the Spotlight index, APFS
        // metadata, root-only files, and any other account's 0700 home. Never named
        // as something it is not.
        let attributed = raw.values.reduce(0, +)
        raw[.unmeasured] = max(0, volume.usedBytes - attributed)
        raw[.free] = volume.freeBytes

        progress?(1.0)

        let breakdown = StorageBreakdown.make(
            capacityBytes: volume.capacityBytes,
            rawSegments: raw,
            unreadableCount: homeUnreadable + systemDataUnreadable
                + dataSideSystem.unreadableCount + systemApplications.unreadableCount
        )

        return StorageMeasurement(
            home: home,
            volume: volume,
            breakdown: breakdown,
            rawSegments: raw,
            homeTree: homeTree,
            rootMeasurements: rootMeasurements,
            nodeDepth: Self.homeWalkDepth
        )
    }

    // MARK: - Which segment owns a path

    /// The segment that counts the bytes at a home-relative path.
    ///
    /// The single source is the `HomePath` table above, read longest match first, so
    /// `Library/Caches/Homebrew` lands in Package & Build Caches rather than in the
    /// App Data & Caches entry it sits inside. Anything in home that no table names
    /// is Other Files in Home, which is exactly how the residual above is computed.
    ///
    /// Returns `nil` for a folder that holds several segments at once, and the
    /// caller must then not pretend that one segment owns it. There are two:
    ///
    /// * `$HOME`, the empty path, which holds every home segment.
    /// * `~/Library`, which holds App Data & Caches, Package & Build Caches,
    ///   Developer and, in `Mail` or `Mobile Documents`, Other Files in Home.
    ///
    /// One nesting stays inside a named segment rather than splitting it:
    /// `~/Library/Caches` is App Data & Caches, and the Homebrew cache it contains
    /// is Package & Build Caches. A measured size for `~/Library/Caches` therefore
    /// includes bytes that the App Data & Caches segment subtracts. The growth
    /// report reads a node for its path, not for its segment total, and it descends
    /// into `Homebrew` when `Homebrew` is what changed.
    public static func segment(
        forHomeRelativeComponents components: [String]
    ) -> StorageSegmentID? {
        guard !components.isEmpty else { return nil }
        guard components != ["Library"] else { return nil }

        func isUnder(_ root: [String]) -> Bool {
            components.count >= root.count && Array(components.prefix(root.count)) == root
        }

        // Longest match first: the Homebrew cache is inside Library/Caches.
        if isUnder(HomePath.homebrewCache) { return .packageBuildCaches }
        if HomePath.packageCaches.contains(where: isUnder) { return .packageBuildCaches }
        if isUnder(HomePath.developer) { return .developer }
        if HomePath.appData.contains(where: isUnder) { return .appDataCaches }
        if isUnder(HomePath.documents) || isUnder(HomePath.desktop) { return .documentsDesktop }
        if isUnder(HomePath.downloads) { return .downloads }
        if isUnder(HomePath.pictures) { return .photos }
        if isUnder(HomePath.music) { return .music }
        if isUnder(HomePath.movies) { return .movies }
        if isUnder(HomePath.applications) { return .applications }
        return .otherFilesInHome
    }

    /// The segment that counts the bytes at a machine-wide root.
    ///
    /// Returns `nil` for a path this service does not measure, so a caller cannot
    /// file bytes under a name that did not produce them.
    public static func segment(forRoot url: URL) -> StorageSegmentID? {
        let path = url.standardizedFileURL.path
        if path == "/Applications" { return .applications }
        if path == DiskInfoService.dataVolumeMountPoint + "/System" { return .macOSSystem }
        if systemDataRoots.contains(path) { return .systemData }
        return nil
    }
}

/// Everything one disk measurement produced.
///
/// The breakdown is what the capacity card draws. The two measurement tables are
/// what the growth report reads, and they exist only because they were already in
/// memory when the walk finished.
public struct StorageMeasurement: Sendable {
    /// The home folder this walk started from, standardized.
    public let home: URL
    public let volume: VolumeInfo
    public let breakdown: StorageBreakdown
    /// Per-segment bytes before ``StorageBreakdown/make(capacityBytes:rawSegments:unreadableCount:mergeThresholdPercent:)``
    /// folded the small segments into `Other`.
    public let rawSegments: [StorageSegmentID: Int64]
    /// Every directory under `$HOME` down to ``nodeDepth``, `$HOME` included.
    public let homeTree: [URL: SizeMeasurement]
    /// `/Applications`, the Data volume's own `/System`, and each System Data root.
    public let rootMeasurements: [URL: SizeMeasurement]
    public let nodeDepth: Int

    public init(
        home: URL,
        volume: VolumeInfo,
        breakdown: StorageBreakdown,
        rawSegments: [StorageSegmentID: Int64],
        homeTree: [URL: SizeMeasurement],
        rootMeasurements: [URL: SizeMeasurement],
        nodeDepth: Int
    ) {
        self.home = home
        self.volume = volume
        self.breakdown = breakdown
        self.rawSegments = rawSegments
        self.homeTree = homeTree
        self.rootMeasurements = rootMeasurements
        self.nodeDepth = nodeDepth
    }
}
