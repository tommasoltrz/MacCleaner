import Foundation
import Testing
@testable import ScoloCore

@Suite("Application uninstall planning")
struct AppUninstallPlannerTests {

    private final class Sandbox {
        let root: URL
        let home: URL
        let applications: URL
        let userApplications: URL
        let systemLibrary: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-uninstall-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            applications = root.appendingPathComponent("Applications", isDirectory: true)
            userApplications = home.appendingPathComponent("Applications", isDirectory: true)
            systemLibrary = root.appendingPathComponent("Library", isDirectory: true)
            for directory in [home, applications, userApplications, systemLibrary] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func application(
            _ name: String,
            identifier: String?,
            under root: URL? = nil
        ) throws -> URL {
            let url = (root ?? applications).appendingPathComponent("\(name).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ]
            if let identifier { plist["CFBundleIdentifier"] = identifier }
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }

        @discardableResult
        func write(_ relativePath: String, bytes: Int = 4_096) throws -> URL {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        func planner() -> AppUninstallPlanner {
            AppUninstallPlanner(
                home: home,
                systemLibrary: systemLibrary,
                applicationRoots: [applications, userApplications],
                darwinCache: nil,
                darwinTemp: nil
            )
        }
    }

    @Test("an untrusted bundle identifier creates an application-only plan")
    func untrustedIdentifierKeepsRelatedFiles() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write("Library/Caches/com.vendor.legacy/blob")

        for (name, identifier) in [
            ("Missing Identifier", nil),
            ("Invalid Identifier", "legacy"),
        ] as [(String, String?)] {
            let app = try sandbox.application(name, identifier: identifier)
            let plan = try await sandbox.planner().plan(applicationURL: app)

            #expect(plan.bundleIdentifier == nil)
            #expect(plan.isApplicationOnly)
            #expect(plan.items.map(\.url) == [app])
            #expect(plan.candidateBundleIdentifiers.isEmpty)
            #expect(plan.protectedItems.isEmpty)
            #expect(AppUninstallPlanner.removalIsStillSafe(
                plan.applicationItem,
                in: plan,
                exclusiveBundleIdentifiers: []
            ))
        }
    }

    @Test("exact bundle paths are classified without prefix or group-container guesses")
    func exactCandidatesOnly() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let support = try sandbox.write("Library/Application Support/com.vendor.editor/account.db")
            .deletingLastPathComponent()
        let preference = try sandbox.write("Library/Preferences/com.vendor.editor.plist")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.helper.plist")
        let sharedGroup = try sandbox.write(
            "Library/Group Containers/group.com.vendor.editor/shared.db"
        ).deletingLastPathComponent()
        let launchAgent = try sandbox.write("Library/LaunchAgents/com.vendor.editor.plist")

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let paths = Set(plan.items.map(\.id))

        #expect(paths.contains(app.path))
        #expect(paths.contains(cache.path))
        #expect(paths.contains(support.path))
        #expect(paths.contains(preference.path))
        #expect(paths.contains(launchAgent.path))
        #expect(!paths.contains { $0.contains("editor.helper.plist") })
        #expect(!paths.contains { $0.contains("Group Containers") })
        #expect(plan.preservedPaths.contains(sharedGroup))
    }

    @Test("another installed copy keeps every shared bundle-owned path")
    func duplicateApplicationPreservesSharedData() async throws {
        let sandbox = try Sandbox()
        let selected = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.application("Editor Copy", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.plist")

        let plan = try await sandbox.planner().plan(applicationURL: selected)

        #expect(plan.items.map(\.id) == [selected.path])
    }

    @Test("Homebrew ownership requires one exact app artifact target")
    func homebrewOwnershipIsExact() throws {
        let data = Data(#"""
        {
          "casks": [
            {
              "token": "editor",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications/Editor.app" }
              ]
            },
            {
              "token": "editor-beta",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications Beta/Editor.app" }
              ]
            }
          ]
        }
        """#.utf8)

        let package = try #require(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Editor.app"),
            executable: "/opt/homebrew/bin/brew"
        ))

        #expect(package.name == "editor")
        #expect(package.manager == .homebrew)
        #expect(package.uninstallCommand
            == "/opt/homebrew/bin/brew uninstall --cask editor")
        #expect(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Other.app"),
            executable: "/opt/homebrew/bin/brew"
        ) == nil)
    }

    @Test("an embedded helper contributes only its exact identifier")
    func embeddedHelperIdentifiers() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let helpers = app.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        _ = try sandbox.application(
            "Background", identifier: "com.vendor.editor.background", under: helpers
        )
        let helperCache = try sandbox.write("Library/Caches/com.vendor.editor.background/blob")
            .deletingLastPathComponent()
        _ = try sandbox.write("Library/Caches/com.unrelated.helper/blob")

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(plan.items.contains { $0.url == helperCache })
        #expect(!plan.items.contains { $0.url.path.contains("com.unrelated.helper") })
    }

    @Test("known nonstandard Electron roots split caches from profiles")
    func knownCurationIsSharedWithTheScanner() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Visual Studio Code", identifier: "com.microsoft.VSCode")
        let cache = try sandbox.write("Library/Application Support/Code/Code Cache/index")
            .deletingLastPathComponent()
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        _ = try sandbox.write("Library/Application Support/Code/User/settings.json")

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let cacheItem = try #require(plan.items.first { $0.url == cache })
        let remainder = try #require(plan.items.first {
            $0.url == support && $0.content == .userData
        })

        #expect(cacheItem.content == .regenerable)
        #expect(remainder.displayName == "Visual Studio Code settings and data")

        // Moving the real support root necessarily carries anything nested inside
        // it. The plan moves the child first so both rows receive honest receipts.
        let order = plan.removalOrder()
        let cacheIndex = try #require(order.firstIndex(of: cacheItem))
        let remainderIndex = try #require(order.firstIndex(of: remainder))
        #expect(cacheIndex < remainderIndex)
    }

    @Test("an excluded related path is preserved and disclosed")
    func exclusionsRemainAbsolute() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let context = ScanContext(excludedPaths: [cache.path])

        let plan = try await sandbox.planner().plan(applicationURL: app, context: context)

        #expect(!plan.items.contains { $0.url == cache })
        #expect(plan.preservedPaths == [cache])
    }

    @Test("the app bundle is always first, before protected data")
    func removalOrderStartsWithApplication() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Application Support/com.vendor.editor/profile.db")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        let plan = try await sandbox.planner().plan(applicationURL: app)

        let order = plan.removalOrder()

        #expect(order.first?.url == app)
        #expect(order.dropFirst().contains { $0.content == .userData })
    }

    @Test("a replacement at a reviewed path is refused by filesystem identity")
    func replacementPathIsNotTheReviewedItem() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/old")
            .deletingLastPathComponent()
        let plan = try await sandbox.planner().plan(applicationURL: app)
        let item = try #require(plan.items.first { $0.url == cache })

        try FileManager.default.removeItem(at: cache)
        _ = try sandbox.write("Library/Caches/com.vendor.editor/replacement")
        let exclusive = AppUninstallPlanner.exclusiveBundleIdentifiers(
            candidates: plan.candidateBundleIdentifiers,
            selectedApplication: plan.applicationURL,
            applicationRoots: plan.applicationRoots
        )

        #expect(!AppUninstallPlanner.removalIsStillSafe(
            item, in: plan, exclusiveBundleIdentifiers: exclusive
        ))
    }

    @Test("a changed app bundle stops the uninstall before related data")
    func applicationFailureIsATransactionGate() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let supportFile = try sandbox.write(
            "Library/Application Support/com.vendor.editor/profile.db"
        )
        let plan = try await sandbox.planner().plan(applicationURL: app)

        // Replace the reviewed bundle at the same path. The location still looks
        // right, but it is no longer the filesystem object the user reviewed.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("reviewed-bundle")
        )
        _ = try sandbox.application("Editor", identifier: "com.vendor.editor")

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [app.path])
        #expect(FileManager.default.fileExists(atPath: supportFile.path))
    }

    @Test("a failed child cannot be carried away by its containing parent")
    func changedChildProtectsItsContainingFolder() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application(
            "Visual Studio Code", identifier: "com.microsoft.VSCode"
        )
        let cache = try sandbox.write(
            "Library/Application Support/Code/Code Cache/index"
        ).deletingLastPathComponent()
        let settings = try sandbox.write(
            "Library/Application Support/Code/User/settings.json"
        )
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        let plan = try await sandbox.planner().plan(applicationURL: app)
        #expect(plan.items.contains {
            $0.url == support && $0.content == .userData
        })

        // A missing app already satisfies the requested app-removal state, but a
        // replacement inside the reviewed support tree is a different object and
        // must survive even when the containing remainder is part of the plan.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("already-removed-app")
        )
        try FileManager.default.moveItem(
            at: cache, to: sandbox.root.appendingPathComponent("reviewed-cache")
        )
        let replacement = try sandbox.write(
            "Library/Application Support/Code/Code Cache/replacement"
        )

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed.contains(cache.path))
        #expect(outcome.failed.contains(support.path))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }

    @Test("system identifiers and symbolic-link applications are refused")
    func protectedAndSymbolicApplicationsAreRefused() async throws {
        let sandbox = try Sandbox()
        let system = try sandbox.application("System", identifier: "com.apple.systemtool")
        await #expect(throws: AppUninstallPlanningError.protectedApplication) {
            _ = try await sandbox.planner().plan(applicationURL: system)
        }

        let real = try sandbox.application("Real", identifier: "com.vendor.real")
        let link = sandbox.applications.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: AppUninstallPlanningError.symbolicLink) {
            _ = try await sandbox.planner().plan(applicationURL: link)
        }
    }

    @Test("the installed list offers exactly what a plan would accept")
    func installedApplicationsMatchThePlanner() async throws {
        let sandbox = try Sandbox()
        try sandbox.application("Zed", identifier: "com.vendor.zed")
        try sandbox.application("alpha", identifier: "com.vendor.alpha",
                                under: sandbox.userApplications)
        try sandbox.application("No Identifier", identifier: nil)
        try sandbox.application("System", identifier: "com.apple.systemtool")
        try sandbox.application("Scolo", identifier: "com.tommasolaterza.Scolo")
        let excluded = try sandbox.application("Excluded", identifier: "com.vendor.excluded")
        let real = try sandbox.application("Real", identifier: "com.vendor.real")
        try FileManager.default.createSymbolicLink(
            at: sandbox.applications.appendingPathComponent("Linked.app"),
            withDestinationURL: real
        )
        // One level into a vendor folder — `Python 3.12/IDLE.app` — and no further.
        let vendor = sandbox.applications.appendingPathComponent("Vendor", isDirectory: true)
        try sandbox.application("Nested", identifier: "com.vendor.nested", under: vendor)
        try sandbox.application(
            "Buried", identifier: "com.vendor.buried",
            under: vendor.appendingPathComponent("Deeper", isDirectory: true)
        )
        // What an excluded vendor folder holds is excluded with it.
        let shut = sandbox.applications.appendingPathComponent("Shut", isDirectory: true)
        try sandbox.application("Hidden", identifier: "com.vendor.hidden", under: shut)
        // A link out of the root is not a vendor folder.
        let outside = sandbox.home.appendingPathComponent("Elsewhere", isDirectory: true)
        try sandbox.application("Outsider", identifier: "com.vendor.outsider", under: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.applications.appendingPathComponent("LinkedFolder"),
            withDestinationURL: outside
        )

        let context = ScanContext(excludedPaths: [excluded.path, shut.path])
        let listed = sandbox.planner().installedApplications(context: context)

        #expect(listed.map(\.name) == ["alpha", "Nested", "No Identifier", "Real", "Zed"])
        #expect(listed.first { $0.name == "No Identifier" }?.bundleIdentifier == nil)
        // Every card must open a review: nothing listed may be refused by the plan.
        for application in listed {
            _ = try await sandbox.planner().plan(applicationURL: application.url, context: context)
        }
    }

    // MARK: - Apple identifiers

    /// A bundle with the App Store's receipt in it, as Pages or Xcode has.
    private static func addAppStoreReceipt(to application: URL) throws {
        let receipt = application.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x30, count: 64).write(to: receipt)
    }

    /// `com.apple.` was refused outright until 19 Sep 2026, which on a real Mac
    /// refused Pages, Numbers, Keynote, iMovie and Xcode — App Store installs — and
    /// nothing else: system applications are not in `/Applications` to be refused.
    @Test("an Apple application is offered on an App Store receipt, and refused without one")
    func appleApplicationsNeedAReceipt() async throws {
        let sandbox = try Sandbox()
        let pages = try sandbox.application("Pages", identifier: "com.apple.iWork.Pages")
        try Self.addAppStoreReceipt(to: pages)
        let unknown = try sandbox.application("Unknown", identifier: "com.apple.unknowntool")

        let listed = sandbox.planner().installedApplications()
        #expect(listed.map(\.name) == ["Pages"])
        _ = try await sandbox.planner().plan(applicationURL: pages)
        await #expect(throws: AppUninstallPlanningError.protectedApplication) {
            _ = try await sandbox.planner().plan(applicationURL: unknown)
        }
    }

    @Test("under an Apple identifier only the exact name is matched, and the shared group stays")
    func appleApplicationMatchesItsExactIdentifierOnly() async throws {
        let sandbox = try Sandbox()
        let pages = try sandbox.application("Pages", identifier: "com.apple.iWork.Pages")
        try Self.addAppStoreReceipt(to: pages)
        // Embedded, and named beneath the application — a vendor's helper would be
        // claimed by the prefix rule. Under `com.apple.` it is not.
        try sandbox.application(
            "Helper", identifier: "com.apple.iWork.Pages.helper",
            under: pages.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        )
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Pages/blob")
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Pages.helper/blob")
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Numbers/blob")
        _ = try sandbox.write("Library/Group Containers/group.com.apple.iWork.Pages/shared.db")

        let plan = try await sandbox.planner().plan(applicationURL: pages)
        let paths = plan.items.map(\.url.path)

        #expect(!plan.isApplicationOnly)
        #expect(paths.contains { $0.hasSuffix("/Library/Caches/com.apple.iWork.Pages") })
        #expect(!paths.contains { $0.contains("com.apple.iWork.Pages.helper") })
        #expect(!paths.contains { $0.contains("com.apple.iWork.Numbers") })
        #expect(!paths.contains { $0.contains("/Group Containers/") })
        #expect(plan.preservedPaths.contains { $0.path.contains("group.com.apple.iWork.Pages") })
    }

    /// Every droplet Shortcuts makes carries `com.apple.shortcuts.droplet`, so what
    /// that name matches belongs to all of them and to none.
    @Test("a Shortcuts droplet is the application alone, with its identifier still shown")
    func shortcutsDropletIsApplicationOnly() async throws {
        let sandbox = try Sandbox()
        let droplet = try sandbox.application(
            "Light Mode", identifier: "com.apple.shortcuts.droplet", under: sandbox.userApplications
        )
        _ = try sandbox.write("Library/Preferences/com.apple.shortcuts.droplet.plist")

        #expect(sandbox.planner().installedApplications().map(\.name) == ["Light Mode"])
        let plan = try await sandbox.planner().plan(applicationURL: droplet)
        #expect(plan.isApplicationOnly)
        #expect(plan.bundleIdentifier == "com.apple.shortcuts.droplet")
        #expect(plan.items.map(\.url) == [droplet])
    }

    /// `Install macOS Sonoma.app` is twelve gigabytes and the first thing anyone
    /// would clear. Fetched through Software Update or `softwareupdate
    /// --fetch-full-installer` it carries no App Store receipt, so the receipt rule
    /// refused it: a row the size of the scan that nothing could remove.
    @Test("a macOS installer is removable on its own, with or without a receipt")
    func macOSInstallerIsApplicationOnly() async throws {
        let sandbox = try Sandbox()
        let installer = try sandbox.application(
            "Install macOS Sonoma", identifier: "com.apple.InstallAssistant.macOSSonoma"
        )
        _ = try sandbox.write("Library/Preferences/com.apple.InstallAssistant.macOSSonoma.plist")

        #expect(sandbox.planner().installedApplications().map(\.name) == ["Install macOS Sonoma"])
        let plan = try await sandbox.planner().plan(applicationURL: installer)
        // The installer alone: what else answers to an Apple name is not knowable.
        #expect(plan.isApplicationOnly)
        #expect(plan.items.map(\.url) == [installer])
        #expect(plan.bundleIdentifier == "com.apple.InstallAssistant.macOSSonoma")
    }

    @Test("a browser's web-application launcher is not listed")
    func chromiumShimIsNotListed() throws {
        let sandbox = try Sandbox()
        let folder = sandbox.userApplications
            .appendingPathComponent("Chrome Apps.localized", isDirectory: true)
        let shim = try sandbox.application(
            "Some Site", identifier: "com.google.Chrome.app.abcdefgh", under: folder
        )
        let plistURL = shim.appendingPathComponent("Contents/Info.plist")
        var plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        plist["CrAppModeShortcutID"] = "abcdefgh"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: plistURL)
        try sandbox.application("Real Tool", identifier: "com.vendor.tool", under: folder)

        // Recognised by what it is, not by the folder it sits in.
        #expect(sandbox.planner().installedApplications().map(\.name) == ["Real Tool"])
    }
}
