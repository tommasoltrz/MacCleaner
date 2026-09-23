import AppKit
import ScoloCore

/// Reads application owners and process state from macOS.
@MainActor
enum ApplicationRuntime {
    static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>,
        stagedApplicationRoots: [URL] = []
    ) -> Set<String> {
        return OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            isInstalled: { identifier in
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).contains { application in
                    OrphanedAppLeftoverPlanner.registeredApplicationIsOwner(
                        at: application, stagedApplicationRoots: stagedApplicationRoots
                    )
                }
            }
        )
    }

    static func currentRunningOwners() -> [FileEntry.RunningOwner] {
        var seen: Set<FileEntry.RunningOwner> = []
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated, let url = application.bundleURL else { return nil }
            let owner = owner(
                bundleURL: url, identifier: application.bundleIdentifier,
                name: application.localizedName
            )
            guard owner.bundleIdentifier != Bundle.main.bundleIdentifier,
                  owner.bundleIdentifier != "com.apple.finder",
                  seen.insert(owner).inserted else { return nil }
            return owner
        }
    }

    /// A nested helper belongs to its enclosing application. Other services keep their own identity.
    static func owner(bundleURL: URL, identifier: String?, name: String?) -> FileEntry.RunningOwner {
        let bundleURL = bundleURL.standardizedFileURL
        var enclosing = bundleURL.deletingLastPathComponent()
        var applicationURL = bundleURL
        while enclosing.path != "/" {
            if enclosing.pathExtension == "app" { applicationURL = enclosing }
            enclosing.deleteLastPathComponent()
        }
        if applicationURL != bundleURL, let bundle = Bundle(url: applicationURL),
           let parentIdentifier = bundle.bundleIdentifier {
            return FileEntry.RunningOwner(
                name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? applicationURL.deletingPathExtension().lastPathComponent,
                bundleIdentifier: parentIdentifier, bundlePath: applicationURL.path
            )
        }
        return FileEntry.RunningOwner(
            name: name ?? bundleURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier, bundlePath: bundleURL.path
        )
    }

    static func processes(of owner: FileEntry.RunningOwner) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: owner.bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { application in
            if let identifier = owner.bundleIdentifier,
               application.bundleIdentifier == identifier { return true }
            guard let url = application.bundleURL?.standardizedFileURL else { return false }
            return url.path == path || url.path.hasPrefix(path + "/")
        }
    }

    static func stillRunning(
        _ owners: [FileEntry.RunningOwner]
    ) -> [FileEntry.RunningOwner] {
        var seen: Set<FileEntry.RunningOwner> = []
        return owners.filter { seen.insert($0).inserted && !processes(of: $0).isEmpty }
    }

    static func isAppDataPath(_ path: String) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path
        return path.hasPrefix(library + "/Containers/")
            || path.hasPrefix(library + "/Group Containers/")
    }
}
