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
        .contentModificationDateKey
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
                let protection = Self.protectionReason(
                    for: child,
                    kind: kind,
                    measurement: measurement,
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
        kind: StorageExplorerItem.Kind,
        measurement: SizeMeasurement,
        identity: String?,
        exclusions: [String],
        home: URL
    ) -> StorageExplorerItem.ProtectionReason? {
        let path = url.standardizedFileURL.path
        if touchesExclusion(path, exclusions: exclusions) { return .excluded }
        if measurement.containsProtectedPattern { return .protectedContents }
        if measurement.unreadableCount > 0 { return .unreadableContents }
        if isSystemManaged(url, home: home) { return .system }
        if kind == .application { return .application }
        if kind == .package { return .package }
        if kind == .volume { return .volume }
        if identity == nil { return .unavailable }
        return nil
    }

    private static func touchesExclusion(_ path: String, exclusions: [String]) -> Bool {
        exclusions.contains { exclusion in
            path == exclusion
                || path.hasPrefix(exclusion + "/")
                || exclusion.hasPrefix(path + "/")
        }
    }

    private static func isSystemManaged(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if systemManagedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        if path.hasPrefix("/Users/"),
           path != home.path,
           !path.hasPrefix(home.path + "/") {
            return true
        }
        if url.deletingLastPathComponent().standardizedFileURL.path == "/" { return true }
        if path == home.path { return true }
        let homeLibrary = home.appendingPathComponent("Library").path
        if path == homeLibrary || path.hasPrefix(homeLibrary + "/") { return true }
        let homeTrash = home.appendingPathComponent(".Trash").path
        if path == homeTrash || path.hasPrefix(homeTrash + "/") { return true }
        return false
    }
}
