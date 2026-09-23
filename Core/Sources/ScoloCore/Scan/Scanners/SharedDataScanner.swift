import Foundation

/// Lists shared storage without treating its location as proof that removal is safe.
public struct SharedDataScanner: CategoryScanner {
    public let id = CategoryID.sharedData
    private let root: URL
    private let applicationRoots: [URL]

    public init() {
        root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    init(root: URL, applicationRoots: [URL] = []) {
        self.root = root.standardizedFileURL
        self.applicationRoots = applicationRoots
    }

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        try Task.checkCancellation()
        guard !context.isWithinExclusion(root) else { return .empty(id) }
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return .empty(id) }
        guard !AppUninstallPlanner.isSymbolicLink(root) else { return .empty(id) }
        let known = SharedApplicationData.discover(in: root)
        var unreadable = known.unreadableCount
        let installedApps = AppUninstallPlanner.installedApplications(in: applicationRoots, fileManager: manager)
        var ownerNames: [String: String] = [:]
        for url in installedApps {
            if let identifier = Bundle(url: url)?.bundleIdentifier {
                ownerNames[identifier] = url.deletingPathExtension().lastPathComponent
            }
        }
        for owner in context.runningApplications {
            if let identifier = owner.bundleIdentifier { ownerNames[identifier] = owner.name }
        }
        var installed = Set(ownerNames.keys)
        installed.formUnion(context.registeredApplicationBundleIdentifiers)
        installed.formUnion(context.runningApplications.compactMap(\.bundleIdentifier))
        let stagedRoots = known.candidates.compactMap(\.stagedApplicationRoot)
        var entries: [FileEntry] = []

        func direct(_ url: URL) -> Bool {
            SharedApplicationData.Candidate.isDirectPath(url, root: root)
        }

        func visit(_ directory: URL) async throws {
            try Task.checkCancellation()
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )
            } catch { unreadable += 1; return }
            for url in children.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard direct(url), !context.isWithinExclusion(url) else { continue }
                let path = url.standardizedFileURL.path
                // Split only the ancestors of known paths. Sibling folders retain their own rows.
                if known.candidates.contains(where: { $0.url.standardizedFileURL.path.hasPrefix(path + "/") }) {
                    try await visit(url)
                    continue
                }
                guard !context.isExcluded(url) else { continue }
                let previousUnreadable = unreadable
                let owners = try protectedOwners(at: url, excluding: stagedRoots, context: context, unreadable: &unreadable)
                let candidate = known.candidates.first { $0.url.standardizedFileURL.path == path }
                var activeOwners = Set(candidate?.ownerIdentifiers.filter {
                    AppUninstallPlanner.ownerIsInstalled($0, installedBundleIdentifiers: installed)
                } ?? [])
                activeOwners.formUnion(owners.keys)
                ownerNames.merge(owners) { existing, _ in existing }
                // These explicit vendor roots can serve more than one installed application.
                let vendorPrefix: String? = switch url.lastPathComponent {
                case "Adobe", "AdobeGCInfo": "com.adobe."
                case "McNeel": "com.mcneel."
                default: nil
                }
                if let vendorPrefix {
                    activeOwners.formUnion(installed.filter { $0.lowercased().hasPrefix(vendorPrefix) })
                }
                let size = try await context.measurer.measure(url)
                unreadable += size.unreadableCount
                guard size.allocatedBytes > 0, !size.containsProtectedPattern else { continue }
                let names = activeOwners.sorted().map { ownerNames[$0] ?? $0 }.joined(separator: ", ")
                let containsLibrary = owners.keys.contains { $0.hasPrefix("media-library:") }
                let containedApps = owners.filter { !$0.key.hasPrefix("media-library:") }
                let containedNames = containedApps.values.sorted().map { "\($0).app" }.joined(separator: ", ")
                let running = context.runningApplications.contains { owner in
                    owner.bundleIdentifier.map { activeOwners.contains($0) } ?? false
                } || context.runningApplicationPaths.contains { runningPath in
                    AppUninstallPlanner.isInside(
                        URL(fileURLWithPath: runningPath).resolvingSymlinksInPath(),
                        root: url.resolvingSymlinksInPath()
                    )
                }
                // An embedded application proves presence, not current use. Its removal requires explicit authorization.
                let canUnlock = !containedApps.isEmpty && !containsLibrary && !running
                    && unreadable == previousUnreadable
                    && activeOwners.isSubset(of: Set(containedApps.keys))
                let reason: String?
                if unreadable > previousUnreadable {
                    reason = "Scolo cannot read all contents. Removal stays disabled because ownership is incomplete."
                } else if containsLibrary {
                    reason = "This folder contains an Apple media library. Manage its contents in the owning application."
                } else if running {
                    reason = "An application in this folder is running. Quit it and scan again before removal."
                } else if canUnlock {
                    reason = nil
                } else if !activeOwners.isEmpty {
                    reason = "Application data: \(names). Scolo keeps these files locked."
                } else if candidate != nil {
                    reason = "Known application data. Use Application Leftovers to review removal after Scolo checks its owners."
                } else {
                    reason = nil
                }
                entries.append(FileEntry(
                    url: url, kind: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? .folder : .file,
                    allocatedBytes: size.allocatedBytes, lastOpened: lastOpenedDate(for: url),
                    protectionReason: canUnlock ? .userData : nil,
                    inventoryReason: reason,
                    userDataRemovalWarning: canUnlock
                        ? "This folder contains \(containedNames) and may contain saved game or application data. Removal moves the complete folder to the Trash."
                        : nil,
                    safetyCaveat: !containedNames.isEmpty ? "Contains \(containedNames)"
                        : (!names.isEmpty ? "Used by \(names)"
                            : (reason == nil ? "Owner unknown. Review before removal." : nil))
                ))
            }
        }
        try await visit(root)
        return ScanCategoryResult(
            categoryID: id, totalBytes: entries.reduce(0) { $0 + $1.displayBytes }, entries: entries,
            availability: entries.isEmpty
                ? (unreadable > 0 ? .unavailable(reason: "Scolo cannot read Shared Data. Check folder access and scan again.") : .empty)
                : .available,
            unreadableCount: unreadable
        )
    }

    /// An application bundle inside shared storage is evidence that the data can still have an owner.
    private func protectedOwners(
        at url: URL, excluding stagedRoots: [URL], context: ScanContext, unreadable: inout Int
    ) throws -> [String: String] {
        let manager = FileManager.default
        var owners: [String: String] = [:]
        func record(_ candidate: URL) {
            guard !stagedRoots.contains(where: { AppUninstallPlanner.isInside(candidate, root: $0) }) else { return }
            let name = candidate.deletingPathExtension().lastPathComponent
            owners[Bundle(url: candidate)?.bundleIdentifier ?? candidate.lastPathComponent] = name
        }
        func recordLibrary(_ candidate: URL) -> Bool {
            guard AppleMediaLibrary.contains(candidate, home: root) else { return false }
            owners["media-library:" + candidate.path] = "Apple media library"
            return true
        }
        if recordLibrary(url) { return owners }
        if url.pathExtension.lowercased() == "app" { record(url); return owners }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return owners }
        // Collect failures after enumeration; the callback does not escape this method.
        var failures = 0
        guard let walker = manager.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in failures += 1; return true }
        ) else { unreadable += 1; return owners }
        for case let child as URL in walker {
            try Task.checkCancellation()
            if AppUninstallPlanner.isSymbolicLink(child) || context.isWithinExclusion(child) {
                walker.skipDescendants()
                continue
            }
            if recordLibrary(child) {
                walker.skipDescendants()
                continue
            }
            if child.pathExtension.lowercased() == "app" {
                record(child)
                walker.skipDescendants()
            }
        }
        unreadable += failures
        return owners
    }
}
