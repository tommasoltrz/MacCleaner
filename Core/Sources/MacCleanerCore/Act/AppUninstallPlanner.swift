import Darwin
import Foundation

/// A reviewed, immutable description of one application uninstall.
///
/// The plan uses exact bundle identifiers or explicit app data rules for related files.
/// If the identifier is not valid, the plan contains only the application.
/// Cleanup checks each path again before it moves any item.
public struct AppUninstallPlan: Sendable, Equatable, Identifiable {

    public struct ManagedPackage: Sendable, Equatable {
        public enum Manager: String, Sendable {
            case homebrew = "Homebrew"
        }

        public let manager: Manager
        public let name: String
        public let executable: String

        public var uninstallCommand: String {
            "\(executable) uninstall --cask \(name)"
        }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public enum Category: String, Sendable, CaseIterable {
            case application
            case support
            case caches
            case preferences
            case containers
            case logs
            case state
            case helpers
        }

        /// What kind of app-owned content this item contains.
        public enum Content: String, Sendable {
            /// The target `.app` bundle. It is mandatory and always goes first.
            case application
            /// Scratch data the app recreates.
            case regenerable
            /// Launch items and privileged helpers that exist only for the app.
            case appComponent
            /// Profiles, preferences, documents, sessions, and other user state.
            case userData
        }

        public var id: String { url.standardizedFileURL.path }
        public let url: URL
        public let displayName: String
        public let category: Category
        public let content: Content
        public let allocatedBytes: Int64
        public let ownerBundleIdentifier: String?
        let plannedIdentity: String?

        public var isProtectedUserData: Bool { content == .userData }

        init(
            url: URL,
            displayName: String? = nil,
            category: Category,
            content: Content,
            allocatedBytes: Int64,
            ownerBundleIdentifier: String?
        ) {
            self.url = url.standardizedFileURL
            self.displayName = displayName ?? url.lastPathComponent
            self.category = category
            self.content = content
            self.allocatedBytes = allocatedBytes
            self.ownerBundleIdentifier = ownerBundleIdentifier
            self.plannedIdentity = FileIdentity.of(url)
        }

        var fileEntry: FileEntry {
            let kind: FileEntry.Kind = switch category {
            case .application: .appBundle
            case .caches, .logs, .state: .cache
            case .preferences: .file
            case .support, .containers, .helpers: .folder
            }
            return FileEntry(
                url: url,
                displayName: displayName,
                kind: kind,
                allocatedBytes: allocatedBytes,
                isRegenerable: content == .regenerable,
                protectionReason: content == .userData ? .userData : nil
            )
        }
    }

    public var id: String { applicationURL.path }
    public let applicationURL: URL
    public let applicationName: String
    public let bundleIdentifier: String?
    public let items: [Item]
    /// Package ownership is informational and a hard direct-removal gate. The
    /// package manager must remove its own receipt and app artifact together.
    public let managedPackage: ManagedPackage?
    /// Candidate roots suppressed by an explicit exclusion or protected glob,
    /// plus shared group containers that cannot be attributed to one app safely.
    /// They are never included in the uninstall plan and are named in the UI.
    public let preservedPaths: [URL]

    let candidateBundleIdentifiers: Set<String>
    let applicationRoots: [URL]
    let allowedRelatedRoots: [URL]

    public var applicationItem: Item { items[0] }
    public var isApplicationOnly: Bool { bundleIdentifier == nil }
    public var protectedItems: [Item] { items.filter(\.isProtectedUserData) }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }

    /// Mandatory app first, then every related item. If the bundle cannot
    /// move, cleanup aborts before profiles or settings can be touched.
    func removalOrder() -> [Item] {
        // Nested paths before their containing folder. This both honours the
        // review rows and gives each moved subtree its own accurate receipt before
        // the curated remainder root follows.
        let related = items.dropFirst()
            .sorted {
                let lhsDepth = $0.url.pathComponents.count
                let rhsDepth = $1.url.pathComponents.count
                if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        return [applicationItem] + related
    }

    init(
        applicationURL: URL,
        applicationName: String,
        bundleIdentifier: String?,
        items: [Item],
        managedPackage: ManagedPackage?,
        preservedPaths: [URL],
        candidateBundleIdentifiers: Set<String>,
        applicationRoots: [URL],
        allowedRelatedRoots: [URL]
    ) {
        precondition(items.first?.content == .application)
        self.applicationURL = applicationURL.standardizedFileURL
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.items = items
        self.managedPackage = managedPackage
        self.preservedPaths = preservedPaths
        self.candidateBundleIdentifiers = candidateBundleIdentifiers
        self.applicationRoots = applicationRoots.map(\.standardizedFileURL)
        self.allowedRelatedRoots = allowedRelatedRoots.map(\.standardizedFileURL)
    }
}

public enum AppUninstallPlanningError: Error, Sendable, Equatable, LocalizedError {
    case notAnApplication
    case untrustedLocation
    case protectedApplication
    case symbolicLink
    case applicationExcluded
    case protectedContent(String)
    case packageOwnershipUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAnApplication:
            "Choose a valid macOS application bundle."
        case .untrustedLocation:
            "Only applications installed in /Applications or your Applications folder can be uninstalled."
        case .protectedApplication:
            "System applications and MacCleaner itself cannot be removed here."
        case .symbolicLink:
            "This application is reached through a symbolic link. Reveal and remove the original application instead."
        case .applicationExcluded:
            "This application is protected by an exclusion in MacCleaner settings."
        case .protectedContent(let path):
            "The application contains protected content at \(path), so MacCleaner will not offer it for removal."
        case .packageOwnershipUnavailable:
            "Homebrew is installed but its package catalog could not be read. Try again before removing this application."
        }
    }
}

/// Builds exact, reviewable uninstall plans for installed applications.
public struct AppUninstallPlanner: Sendable {
    let home: URL
    let userLibrary: URL
    let systemLibrary: URL
    let applicationRoots: [URL]
    let darwinCache: URL?
    let darwinTemp: URL?
    private let homebrewExecutable: String?
    private let processRunner: ProcessRunner
    let protectedBundleIdentifiers: Set<String>

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.init(
            home: home,
            systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
            ],
            darwinCache: Self.darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinTemp: Self.darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR),
            homebrewExecutable: Self.homebrewExecutables.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }),
            protectedBundleIdentifiers: [
                "com.tommasolaterza.MacCleaner",
                Bundle.main.bundleIdentifier ?? "com.tommasolaterza.MacCleaner",
            ]
        )
    }

    /// Internal configuration point used by deterministic sandbox tests.
    init(
        home: URL,
        systemLibrary: URL,
        applicationRoots: [URL],
        darwinCache: URL?,
        darwinTemp: URL?,
        homebrewExecutable: String? = nil,
        processRunner: ProcessRunner = ProcessRunner(),
        protectedBundleIdentifiers: Set<String> = ["com.tommasolaterza.MacCleaner"]
    ) {
        self.home = home.standardizedFileURL
        self.userLibrary = home.appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL
        self.systemLibrary = systemLibrary.standardizedFileURL
        self.applicationRoots = applicationRoots.map(\.standardizedFileURL)
        self.darwinCache = darwinCache?.standardizedFileURL
        self.darwinTemp = darwinTemp?.standardizedFileURL
        self.homebrewExecutable = homebrewExecutable
        self.processRunner = processRunner
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
    }

    public func plan(
        applicationURL rawApplicationURL: URL,
        context: ScanContext = ScanContext()
    ) async throws -> AppUninstallPlan {
        let fm = FileManager.default
        let applicationURL = rawApplicationURL.standardizedFileURL
        guard applicationURL.pathExtension.lowercased() == "app",
              fm.fileExists(atPath: applicationURL.path),
              let bundle = Bundle(url: applicationURL)
        else { throw AppUninstallPlanningError.notAnApplication }
        guard Self.isInside(applicationURL, oneOf: applicationRoots) else {
            throw AppUninstallPlanningError.untrustedLocation
        }
        guard !Self.isSymbolicLink(applicationURL),
              applicationURL.resolvingSymlinksInPath().standardizedFileURL == applicationURL
        else { throw AppUninstallPlanningError.symbolicLink }
        let bundleIdentifier = Self.verifiedBundleIdentifier(bundle.bundleIdentifier)
        if let bundleIdentifier {
            guard !Self.isProtectedBundleIdentifier(bundleIdentifier),
                  !protectedBundleIdentifiers.contains(bundleIdentifier)
            else { throw AppUninstallPlanningError.protectedApplication }
        }
        guard !context.isExcluded(applicationURL) else {
            throw AppUninstallPlanningError.applicationExcluded
        }

        let applicationMeasurement = try await context.measurer.measure(applicationURL)
        guard !applicationMeasurement.containsProtectedPattern else {
            throw AppUninstallPlanningError.protectedContent(applicationURL.path)
        }

        var name = applicationURL.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = applicationURL.lastPathComponent }

        let managedPackage: AppUninstallPlan.ManagedPackage?
        do {
            managedPackage = try await homebrewPackage(managing: applicationURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Failing open could trash a cask artifact while leaving Homebrew's
            // receipt behind. Ownership uncertainty is therefore a visible stop.
            throw AppUninstallPlanningError.packageOwnershipUnavailable
        }

        let applicationItem = AppUninstallPlan.Item(
            url: applicationURL,
            displayName: name,
            category: .application,
            content: .application,
            allocatedBytes: applicationMeasurement.allocatedBytes,
            ownerBundleIdentifier: nil
        )

        // A missing identifier prevents safe related-file attribution.
        // The reviewed application can still move to the Trash by itself.
        guard let bundleIdentifier else {
            return AppUninstallPlan(
                applicationURL: applicationURL,
                applicationName: name,
                bundleIdentifier: nil,
                items: [applicationItem],
                managedPackage: managedPackage,
                preservedPaths: [],
                candidateBundleIdentifiers: [],
                applicationRoots: applicationRoots,
                allowedRelatedRoots: allowedRelatedRoots
            )
        }

        let candidateIDs = Self.ownedBundleIdentifiers(
            in: applicationURL, primary: bundleIdentifier, fileManager: fm
        )
        let exclusiveIDs = Self.exclusiveBundleIdentifiers(
            candidates: candidateIDs,
            selectedApplication: applicationURL,
            applicationRoots: applicationRoots,
            fileManager: fm
        )

        var items: [AppUninstallPlan.Item] = [applicationItem]
        var preserved: [URL] = []
        var claimedPaths = Set(items.map(\.id))

        // Group containers are allowed to be shared by several applications and
        // their names are entitlement-defined, so even a bundle-ID-shaped match is
        // evidence worth showing, not proof of exclusive ownership. Keep these on
        // disk under every scope and disclose them in the review.
        preserved.append(contentsOf: sharedGroupContainers(for: exclusiveIDs))

        let curation = exclusiveIDs.contains(bundleIdentifier)
            ? ApplicationsScanner.curation(
                bundleID: bundleIdentifier, baseName: name, home: home
            )
            : nil
        let curatedRoot = curation.map {
            home.appendingPathComponent($0.root).standardizedFileURL
        }

        if let curation, let curatedRoot {
            if let curated = try await ApplicationsScanner.curatedChildren(
                curation, home: home, context: context
            ) {
                if curated.holdsProtectedContent {
                    preserved.append(curatedRoot)
                } else {
                    for entry in curated.entries {
                        let item = AppUninstallPlan.Item(
                            url: entry.url,
                            displayName: entry.displayName,
                            category: entry.isRegenerable ? .caches : .support,
                            content: entry.isRegenerable ? .regenerable : .userData,
                            allocatedBytes: entry.allocatedBytes,
                            ownerBundleIdentifier: bundleIdentifier
                        )
                        if claimedPaths.insert(item.id).inserted { items.append(item) }
                    }
                }
            }
        }

        for candidate in candidates(for: exclusiveIDs) {
            try Task.checkCancellation()
            if let curatedRoot,
               ApplicationsScanner.overlaps(candidate.url.standardizedFileURL.path,
                                            curatedRoot.path) {
                continue
            }
            guard fm.fileExists(atPath: candidate.url.path) else { continue }
            guard candidateIsSafe(candidate.url) else {
                preserved.append(candidate.url)
                continue
            }
            guard !context.isExcluded(candidate.url) else {
                preserved.append(candidate.url)
                continue
            }
            let measurement = try await context.measurer.measure(candidate.url)
            guard measurement.allocatedBytes > 0 else { continue }
            guard !measurement.containsProtectedPattern else {
                preserved.append(candidate.url)
                continue
            }
            let item = AppUninstallPlan.Item(
                url: candidate.url,
                category: candidate.category,
                content: candidate.content,
                allocatedBytes: measurement.allocatedBytes,
                ownerBundleIdentifier: candidate.ownerBundleIdentifier
            )
            if claimedPaths.insert(item.id).inserted { items.append(item) }
        }

        let categoryRank = Dictionary(
            uniqueKeysWithValues: AppUninstallPlan.Item.Category.allCases.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let application = items.removeFirst()
        items.sort {
            let lhs = categoryRank[$0.category, default: 0]
            let rhs = categoryRank[$1.category, default: 0]
            if lhs != rhs { return lhs < rhs }
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }

        return AppUninstallPlan(
            applicationURL: applicationURL,
            applicationName: name,
            bundleIdentifier: bundleIdentifier,
            items: [application] + items,
            managedPackage: managedPackage,
            preservedPaths: Self.deduplicated(preserved),
            candidateBundleIdentifiers: candidateIDs,
            applicationRoots: applicationRoots,
            allowedRelatedRoots: allowedRelatedRoots
        )
    }

    // MARK: Candidate discovery

    struct Candidate {
        let url: URL
        let category: AppUninstallPlan.Item.Category
        let content: AppUninstallPlan.Item.Content
        let ownerBundleIdentifier: String
    }

    func candidates(for bundleIdentifiers: Set<String>) -> [Candidate] {
        var result: [Candidate] = []

        func append(
            _ root: URL,
            _ relative: String,
            _ category: AppUninstallPlan.Item.Category,
            _ content: AppUninstallPlan.Item.Content,
            owner: String
        ) {
            result.append(Candidate(
                url: root.appendingPathComponent(relative), category: category,
                content: content, ownerBundleIdentifier: owner
            ))
        }

        for id in bundleIdentifiers.sorted() {
            append(userLibrary, "Application Support/\(id)", .support, .userData, owner: id)
            append(userLibrary, "Containers/\(id)", .containers, .userData, owner: id)
            append(userLibrary, "Caches/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "Preferences/\(id).plist", .preferences, .userData, owner: id)
            append(userLibrary, "Saved Application State/\(id).savedState", .state, .regenerable, owner: id)
            append(userLibrary, "HTTPStorages/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "HTTPStorages/\(id).binarycookies", .caches, .regenerable, owner: id)
            append(userLibrary, "WebKit/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "Application Scripts/\(id)", .containers, .userData, owner: id)
            append(userLibrary, "Cookies/\(id).binarycookies", .preferences, .userData, owner: id)
            append(userLibrary, "Logs/\(id)", .logs, .regenerable, owner: id)

            append(systemLibrary, "Application Support/\(id)", .support, .appComponent, owner: id)
            append(systemLibrary, "Caches/\(id)", .caches, .regenerable, owner: id)
            append(systemLibrary, "Preferences/\(id).plist", .preferences, .userData, owner: id)
            append(systemLibrary, "PrivilegedHelperTools/\(id)", .helpers, .appComponent, owner: id)

            append(home, ".config/\(id)", .support, .userData, owner: id)
            append(home, ".cache/\(id)", .caches, .regenerable, owner: id)
            append(home, ".local/share/\(id)", .support, .userData, owner: id)
            if let darwinCache {
                append(darwinCache, id, .caches, .regenerable, owner: id)
            }
            if let darwinTemp {
                append(darwinTemp, id, .caches, .regenerable, owner: id)
            }

            let byHost = userLibrary.appendingPathComponent("Preferences/ByHost", isDirectory: true)
            for entry in Self.directoryNames(byHost) where Self.matchesByHostPreference(entry, id: id) {
                append(byHost, entry, .preferences, .userData, owner: id)
            }
            for directory in [
                userLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
                systemLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
                systemLibrary.appendingPathComponent("LaunchDaemons", isDirectory: true),
            ] {
                let filename = "\(id).plist"
                if Self.directoryNames(directory).contains(filename) {
                    append(directory, filename, .helpers, .appComponent, owner: id)
                }
            }
        }
        return result
    }

    private func sharedGroupContainers(for bundleIdentifiers: Set<String>) -> [URL] {
        let root = userLibrary.appendingPathComponent("Group Containers", isDirectory: true)
        return Self.directoryNames(root).compactMap { name in
            guard bundleIdentifiers.contains(where: { identifier in
                name == identifier
                    || name == "group.\(identifier)"
                    || name.hasPrefix("group.\(identifier).")
            }) else { return nil }
            return root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        }
    }

    // MARK: Package-manager ownership

    private static let homebrewExecutables = [
        "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
    ]

    private func homebrewPackage(
        managing applicationURL: URL
    ) async throws -> AppUninstallPlan.ManagedPackage? {
        guard let homebrewExecutable else { return nil }
        let data = try await processRunner.run(
            homebrewExecutable,
            ["info", "--json=v2", "--installed"],
            timeout: .seconds(20)
        )
        return try Self.homebrewPackage(
            in: data, managing: applicationURL, executable: homebrewExecutable
        )
    }

    static func homebrewPackage(
        in data: Data,
        managing applicationURL: URL,
        executable: String
    ) throws -> AppUninstallPlan.ManagedPackage? {
        struct Catalog: Decodable { let casks: [Cask] }
        struct Cask: Decodable {
            let token: String
            let artifacts: [Artifact]
        }
        struct Artifact: Decodable { let target: String? }

        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let selectedPath = applicationURL.standardizedFileURL.path
        let matches = catalog.casks.filter { cask in
            Self.validHomebrewToken(cask.token)
                && cask.artifacts.contains { artifact in
                    guard let target = artifact.target else { return false }
                    return Self.expandedHomePath(target).standardizedFileURL.path == selectedPath
                }
        }
        guard matches.count == 1 else { return nil }
        return AppUninstallPlan.ManagedPackage(
            manager: .homebrew,
            name: matches[0].token,
            executable: executable
        )
    }

    private static func validHomebrewToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-"),
              !token.contains(".."), !token.contains("//")
        else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@/-"
        )
        return token.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func expandedHomePath(_ path: String) -> URL {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: Ownership and safety

    static func verifiedBundleIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        for part in parts where part.isEmpty { return nil }
        for scalar in rawValue.unicodeScalars {
            let valid = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "-" || scalar == "_"
            guard valid else { return nil }
        }
        return rawValue
    }

    static func isProtectedBundleIdentifier(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        let wrapped = "." + lowered + "."
        return lowered == "com.apple"
            || wrapped.contains(".com.apple.")
            || wrapped.contains(".developer.apple.")
            || wrapped.contains(".is.workflow.")
    }

    static func ownedBundleIdentifiers(
        in applicationURL: URL,
        primary: String,
        fileManager: FileManager
    ) -> Set<String> {
        var result: Set<String> = [primary]
        for identifier in allBundleIdentifiers(in: applicationURL, fileManager: fileManager)
        where identifier.hasPrefix(primary + ".") {
            result.insert(identifier)
        }
        return result
    }

    static func exclusiveBundleIdentifiers(
        candidates: Set<String>,
        selectedApplication: URL,
        applicationRoots: [URL],
        fileManager: FileManager = .default
    ) -> Set<String> {
        let selectedPath = selectedApplication.resolvingSymlinksInPath().standardizedFileURL.path
        var ownedElsewhere = Set<String>()
        for application in installedApplications(in: applicationRoots, fileManager: fileManager) {
            let path = application.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != selectedPath, !path.hasPrefix(selectedPath + "/") else { continue }
            ownedElsewhere.formUnion(allBundleIdentifiers(in: application, fileManager: fileManager))
        }
        return candidates.subtracting(ownedElsewhere)
    }

    static func removalIsStillSafe(
        _ item: AppUninstallPlan.Item,
        in plan: AppUninstallPlan,
        exclusiveBundleIdentifiers: Set<String>
    ) -> Bool {
        guard plan.items.contains(where: { $0.id == item.id && $0 == item }) else { return false }
        if let currentIdentity = FileIdentity.of(item.url),
           currentIdentity != item.plannedIdentity {
            // The path now names a different filesystem object than the one shown
            // in review. A location is not an identity; leave the replacement.
            return false
        }
        if item.content == .application {
            return item.url == plan.applicationURL
                && Self.isInside(item.url, oneOf: plan.applicationRoots)
                && !Self.isSymbolicLink(item.url)
        }
        guard let owner = item.ownerBundleIdentifier,
              exclusiveBundleIdentifiers.contains(owner),
              let root = plan.allowedRelatedRoots.first(where: {
                  Self.isInside(item.url, root: $0)
              }),
              !Self.isSymbolicLink(item.url)
        else { return false }
        return !Self.hasSymbolicLinkInParents(of: item.url, through: root)
    }

    var allowedRelatedRoots: [URL] {
        [
            userLibrary,
            systemLibrary,
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true),
            home.appendingPathComponent(".local/share", isDirectory: true),
        ] + [darwinCache, darwinTemp].compactMap { $0 }
    }

    func candidateIsSafe(_ url: URL) -> Bool {
        guard let root = allowedRelatedRoots.first(where: { Self.isInside(url, root: $0) }),
              !Self.isSymbolicLink(url)
        else { return false }
        return !Self.hasSymbolicLinkInParents(of: url, through: root)
    }

    static func installedApplications(
        in roots: [URL], fileManager: FileManager
    ) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: nil
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isDirectory == true,
                      url.pathExtension.lowercased() == "app"
                else { continue }
                result.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return result
    }

    static func allBundleIdentifiers(
        in applicationURL: URL, fileManager: FileManager
    ) -> Set<String> {
        var result = Set<String>()
        if let identifier = verifiedBundleIdentifier(Bundle(url: applicationURL)?.bundleIdentifier) {
            result.insert(identifier)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: applicationURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }
            let extensionName = url.pathExtension.lowercased()
            guard ["app", "appex", "xpc", "plugin", "bundle"].contains(extensionName)
            else { continue }
            if let identifier = verifiedBundleIdentifier(Bundle(url: url)?.bundleIdentifier) {
                result.insert(identifier)
            }
            if extensionName == "app" { enumerator.skipDescendants() }
        }
        return result
    }

    private static func matchesByHostPreference(_ name: String, id: String) -> Bool {
        guard name.hasPrefix(id + "."), name.hasSuffix(".plist") else { return false }
        let suffix = String(name.dropFirst(id.count + 1).dropLast(".plist".count))
        return UUID(uuidString: suffix) != nil
    }

    static func installedBundleIdentifiers(
        in roots: [URL], fileManager: FileManager = .default
    ) -> Set<String> {
        installedApplications(in: roots, fileManager: fileManager).reduce(into: Set<String>()) {
            $0.formUnion(allBundleIdentifiers(in: $1, fileManager: fileManager))
        }
    }

    static func ownerIsInstalled(
        _ identifier: String, installedBundleIdentifiers: Set<String>
    ) -> Bool {
        installedBundleIdentifiers.contains { installed in
            identifier == installed
                || identifier.hasPrefix(installed + ".")
                || installed.hasPrefix(identifier + ".")
        }
    }

    static func directoryNames(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    static func isInside(_ url: URL, oneOf roots: [URL]) -> Bool {
        roots.contains { isInside(url, root: $0) }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }

    static func hasSymbolicLinkInParents(of url: URL, through root: URL) -> Bool {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let root = root.standardizedFileURL
        while current.path.count >= root.path.count {
            if isSymbolicLink(current) { return true }
            if current.path == root.path { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return true }
            current = parent
        }
        return true
    }

    private static func darwinUserDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
            .standardizedFileURL
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
