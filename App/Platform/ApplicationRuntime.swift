import AppKit
import ScoloCore

/// Reads application owners and process state from macOS.
@MainActor
enum ApplicationRuntime {
    static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>
    ) -> Set<String> {
        let fileManager = FileManager.default
        return OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            isInstalled: { identifier in
                guard let application = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: identifier
                ) else { return false }
                return fileManager.fileExists(atPath: application.path)
            }
        )
    }

    static func currentRunningOwners() -> [FileEntry.RunningOwner] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier,
                  application.bundleIdentifier != "com.apple.finder"
            else { return nil }
            guard let url = application.bundleURL else { return nil }
            return FileEntry.RunningOwner(
                name: application.localizedName
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: url.path
            )
        }
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
