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

    /// Home-relative paths whose sizes are read out of the single depth-3 walk.
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

    public func breakdown(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StorageBreakdown {
        let home = URL(fileURLWithPath: NSHomeDirectory())

        let volume = try await diskInfo.volumeInfo()
        let dataUsed = try await diskInfo.dataVolumeUsedBytes()
        progress?(0.05)

        // One traversal of $HOME at depth 3 supplies every home figure below,
        // including `Library/Caches/Homebrew`.
        let homeTree = try await measurer.measureSubtrees(of: home, depth: 3)
        progress?(0.55)

        func homeBytes(_ components: [String]) -> Int64 {
            var url = home
            for component in components { url.appendPathComponent(component) }
            return homeTree[url.standardizedFileURL]?.allocatedBytes ?? 0
        }

        let homeTotal = homeTree[home.standardizedFileURL]?.allocatedBytes ?? 0
        let homeUnreadable = homeTree[home.standardizedFileURL]?.unreadableCount ?? 0

        // The Data volume's own /System tree, invisible to any walk of `/`.
        let dataSideSystem = try await measurer.measure(
            URL(fileURLWithPath: DiskInfoService.dataVolumeMountPoint + "/System")
        )
        progress?(0.7)

        var systemDataBytes: Int64 = 0
        var systemDataUnreadable = 0
        for root in Self.systemDataRoots {
            let measured = try await measurer.measure(URL(fileURLWithPath: root))
            systemDataBytes += measured.allocatedBytes
            systemDataUnreadable += measured.unreadableCount
        }
        progress?(0.9)

        let systemApplications = try await measurer.measure(URL(fileURLWithPath: "/Applications"))

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

        return StorageBreakdown.make(
            capacityBytes: volume.capacityBytes,
            rawSegments: raw,
            unreadableCount: homeUnreadable + systemDataUnreadable
                + dataSideSystem.unreadableCount + systemApplications.unreadableCount
        )
    }
}
