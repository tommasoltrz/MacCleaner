import Foundation
import Testing
@testable import ScoloCore

@Suite("Web app removal controls")
struct InstalledWebApplicationTests {
    private let application = InstalledApplication(
        url: URL(fileURLWithPath: "/Applications/Site.app"), name: "Site", bundleIdentifier: "site"
    )

    private func metadata(profile: String = "Profile 2") -> [String: Any] {
        [
            "CrBundleIdentifier": "com.google.Chrome",
            "CrAppModeShortcutID": "abcdefgh",
            "CrAppModeProfileDir": profile,
            "CrAppModeUserDataDir": "/Users/test/Chrome/\(profile.isEmpty ? "-" : profile)/Web Applications/_crx_abcdefgh"
        ]
    }

    @Test func controlsUseTheOwningProfile() {
        let app = InstalledWebApplication(application: application, metadata: metadata())
        #expect(app.removalArguments == [
            "--user-data-dir=/Users/test/Chrome", "--profile-directory=Profile 2", "chrome://apps"
        ])
    }

    @Test func sharedAppsDoNotInventAProfile() {
        let app = InstalledWebApplication(application: application, metadata: metadata(profile: ""))
        #expect(app.removalArguments == ["--user-data-dir=/Users/test/Chrome", "chrome://apps"])
    }

    @Test func incompleteMetadataDoesNotOpenAnotherProfile() {
        #expect(InstalledWebApplication(application: application, metadata: [:]).removalArguments == nil)
        var info = metadata()
        info["CrAppModeUserDataDir"] = "/Users/test/Chrome/Default/Web Applications/_crx_abcdefgh"
        #expect(InstalledWebApplication(application: application, metadata: info).removalArguments == nil)
        info = metadata(profile: "../Default")
        #expect(InstalledWebApplication(application: application, metadata: info).removalArguments == nil)
    }

    @Test func edgeUsesItsOwnControls() {
        var info = metadata()
        info["CrBundleIdentifier"] = "com.microsoft.edgemac"
        #expect(InstalledWebApplication(application: application, metadata: info).removalArguments?.last == "edge://apps")
    }

    @Test func discoverySeparatesWebAppsAndRespectsExclusions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        let site = apps.appendingPathComponent("Chrome Apps.localized/Site.app")
        let contents = site.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = metadata()
        info["CFBundleIdentifier"] = "com.google.Chrome.app.abcdefgh"
        info["CFBundleExecutable"] = "app_mode_loader"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let planner = AppUninstallPlanner(home: root, systemLibrary: root.appendingPathComponent("Library"), applicationRoots: [apps], darwinCache: nil, darwinTemp: nil)
        #expect(planner.installedApplications().isEmpty)
        #expect(planner.installedWebApplications().map(\.application.name) == ["Site"])
        #expect(planner.installedWebApplications(context: ScanContext(excludedPaths: [site.path])).isEmpty)
    }
}
