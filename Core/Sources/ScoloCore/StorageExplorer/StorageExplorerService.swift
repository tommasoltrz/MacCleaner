import Foundation

/// Measures one folder level without counting a file in two sibling rows.
public struct StorageExplorerService: Sendable {
    private let measurer: AllocatedSizeMeasurer
    private let home: URL

    private static let metadataKeys: Set<URLResourceKey> = [
        .localizedNameKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isVolumeKey,
        .isPackageKey,
        .isApplicationKey,
        .isHiddenKey,
        .contentModificationDateKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]
    private static let systemManagedRoots = [
        "/Applications", "/Library", "/System", "/bin", "/cores", "/dev",
        "/home", "/Network", "/opt", "/private", "/sbin", "/usr"
    ]

    public init(
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer(),
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        self.measurer = measurer
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    public func scan(
        directory input: URL,
        excludedPaths: [String] = [],
        excludedPatterns: [String] = [],
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> StorageExplorerSnapshot {
        let directory = input.resolvingSymlinksInPath().standardizedFileURL
        let children = try await readChildren(of: directory)

        var configuredMeasurer = measurer
        configuredMeasurer.protectedPatterns = excludedPatterns
        configuredMeasurer.detectCloudOnlyItems = true
        let measurements = try await configuredMeasurer.measureChildren(
            of: directory,
            progress: progress
        )

        let exclusions = excludedPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let home = home
        let items = await Task.detached(priority: .utility) {
            children.map { child -> StorageExplorerItem in
                let values = try? child.resourceValues(forKeys: Self.metadataKeys)
                let measurement = measurements[child] ?? .zero
                let kind = values.map(Self.kind(for:)) ?? .file
                let identity = FileIdentity.of(child)
                let cloudState = Self.cloudState(
                    isUbiquitousItem: values?.isUbiquitousItem == true,
                    isDownloaded: values?.ubiquitousItemDownloadingStatus == .current,
                    containsCloudOnlyItems: measurement.containsCloudOnlyItem
                )
                let protection = Self.protectionReason(
                    for: child,
                    in: directory,
                    kind: kind,
                    measurement: measurement,
                    cloudState: cloudState,
                    identity: identity,
                    exclusions: exclusions,
                    home: home
                )
                return StorageExplorerItem(
                    url: child,
                    name: values?.localizedName ?? child.lastPathComponent,
                    kind: kind,
                    allocatedBytes: measurement.allocatedBytes,
                    fileCount: measurement.fileCount,
                    unreadableCount: measurement.unreadableCount,
                    modificationDate: values?.contentModificationDate,
                    identity: identity,
                    isHidden: values?.isHidden ?? child.lastPathComponent.hasPrefix("."),
                    cloudState: cloudState,
                    protectionReason: values == nil ? protection ?? .unavailable : protection
                )
            }
        }.value

        return StorageExplorerSnapshot(
            directory: directory,
            items: items,
            allocatedBytes: items.reduce(0) { $0 + $1.allocatedBytes },
            fileCount: items.reduce(0) { $0 + $1.fileCount },
            unreadableCount: items.reduce(0) { $0 + $1.unreadableCount }
        )
    }

    public func reviewSelection(
        _ selectedItems: [StorageExplorerItem],
        in directory: URL,
        excludedPaths: [String] = [],
        excludedPatterns: [String] = []
    ) async throws -> StorageExplorerSelectionReview {
        let snapshot = try await scan(
            directory: directory,
            excludedPaths: excludedPaths,
            excludedPatterns: excludedPatterns
        )
        let refreshed = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        var items: [StorageExplorerItem] = []
        var changedPaths: [String] = []
        var protectedPaths: [String] = []

        for selected in selectedItems {
            guard let item = refreshed[selected.id], item.identity == selected.identity else {
                changedPaths.append(selected.url.path)
                continue
            }
            guard item.isRemovable else {
                protectedPaths.append(item.url.path)
                continue
            }
            items.append(item)
        }

        return StorageExplorerSelectionReview(
            snapshot: snapshot,
            items: items,
            changedPaths: changedPaths,
            protectedPaths: protectedPaths
        )
    }

    private func readChildren(of directory: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]) else {
                throw StorageExplorerError.unavailable(directory.path)
            }
            guard values.isDirectory == true else {
                throw StorageExplorerError.notDirectory(directory.path)
            }
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(Self.metadataKeys),
                    options: []
                )
            } catch {
                throw StorageExplorerError.unavailable(directory.path)
            }
        }.value
    }

    private static func kind(for values: URLResourceValues) -> StorageExplorerItem.Kind {
        if values.isVolume == true { return .volume }
        if values.isSymbolicLink == true { return .symbolicLink }
        if values.isApplication == true { return .application }
        if values.isPackage == true { return .package }
        if values.isDirectory == true { return .folder }
        return .file
    }

    private static func protectionReason(
        for url: URL,
        in directory: URL,
        kind: StorageExplorerItem.Kind,
        measurement: SizeMeasurement,
        cloudState: StorageExplorerItem.CloudState,
        identity: String?,
        exclusions: [String],
        home: URL
    ) -> StorageExplorerItem.ProtectionReason? {
        let path = url.standardizedFileURL.path
        if touchesExclusion(path, exclusions: exclusions) { return .excluded }
        if measurement.containsProtectedPattern { return .protectedContents }
        if measurement.unreadableCount > 0 { return .unreadableContents }
        if let managed = managedLocation(url, in: directory, home: home) { return managed }
        if kind == .application { return .application }
        if AppleMediaLibrary.contains(url, home: home) { return .mediaLibrary }
        if kind == .volume { return .volume }
        if cloudState == .cloudOnly || cloudState == .containsCloudOnlyItems {
            return .cloudOnly
        }
        if identity == nil { return .unavailable }
        return nil
    }

    static func cloudState(
        isUbiquitousItem: Bool,
        isDownloaded: Bool,
        containsCloudOnlyItems: Bool
    ) -> StorageExplorerItem.CloudState {
        if isUbiquitousItem && !isDownloaded { return .cloudOnly }
        if containsCloudOnlyItems { return .containsCloudOnlyItems }
        if isUbiquitousItem { return .downloaded }
        return .none
    }

    private static func touchesExclusion(_ path: String, exclusions: [String]) -> Bool {
        exclusions.contains { exclusion in
            path == exclusion
                || path.hasPrefix(exclusion + "/")
                || exclusion.hasPrefix(path + "/")
        }
    }

    /// Locations another part of the app owns, each with its own reason so the
    /// row can say where to go. `~/Library` is not a "system location" —
    /// `~/Library/Caches/Google` is the Scanner's job, and the lock should say so.
    private static func managedLocation(
        _ url: URL, in directory: URL, home: URL
    ) -> StorageExplorerItem.ProtectionReason? {
        let path = url.standardizedFileURL.path
        let homeLibrary = home.appendingPathComponent("Library").path
        if !isUserCloudDirectory(directory, home: home),
           (path == homeLibrary || path.hasPrefix(homeLibrary + "/")) {
            return .library
        }
        let homeTrash = home.appendingPathComponent(".Trash").path
        if path == homeTrash || path.hasPrefix(homeTrash + "/") { return .trash }

        if systemManagedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .system
        }
        if path.hasPrefix("/Users/"),
           path != home.path,
           !path.hasPrefix(home.path + "/") {
            return .system
        }
        if url.deletingLastPathComponent().standardizedFileURL.path == "/" { return .system }
        if path == home.path { return .system }
        return nil
    }

    /// Returns true for a user document folder backed by a cloud provider.
    private static func isUserCloudDirectory(_ directory: URL, home: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        let cloudDocs = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .standardizedFileURL.path
        if path == cloudDocs || path.hasPrefix(cloudDocs + "/") { return true }

        let providers = home
            .appendingPathComponent("Library/CloudStorage")
            .standardizedFileURL.path
        return path.hasPrefix(providers + "/")
    }
}
