import Foundation

/// A browser web app with a separate removal action.
public struct InstalledWebApplication: Sendable, Identifiable {
    public let application: InstalledApplication
    public let browserIdentifier: String?
    public let profileName: String?
    public let site: String?
    public let removalArguments: [String]?
    public var id: String { application.id }

    init(application: InstalledApplication, metadata: [String: Any]) {
        self.application = application
        browserIdentifier = metadata["CrBundleIdentifier"] as? String
        profileName = metadata["CrAppModeProfileName"] as? String
            ?? (metadata["CrAppModeProfileDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        site = metadata["CrAppModeShortcutURL"] as? String

        // Chromium stores the app directory in this field, not the browser data directory.
        let profile = metadata["CrAppModeProfileDir"] as? String ?? ""
        guard let path = metadata["CrAppModeUserDataDir"] as? String,
              path.hasPrefix("/"),
              profile != ".", profile != "..", !profile.contains("/"),
              let appID = metadata["CrAppModeShortcutID"] as? String,
              !appID.isEmpty, !appID.contains("/") else {
            removalArguments = nil
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        guard directory.lastPathComponent == "_crx_" + appID,
              directory.deletingLastPathComponent().lastPathComponent == "Web Applications",
              directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == (profile.isEmpty ? "-" : profile) else {
            removalArguments = nil
            return
        }
        let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var arguments = ["--user-data-dir=\(root.path)"]
        if !profile.isEmpty { arguments.append("--profile-directory=\(profile)") }
        arguments.append(browserIdentifier == "com.microsoft.edgemac" ? "edge://apps" : "chrome://apps")
        removalArguments = arguments
    }
}
