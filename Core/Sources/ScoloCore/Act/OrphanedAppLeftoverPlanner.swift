import Foundation
import Security

/// A review plan for files that have no installed application owner.
public struct OrphanedAppLeftoverPlan: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { bundleIdentifier }
        public let bundleIdentifier: String
        public let items: [AppUninstallPlan.Item]

        public var totalBytes: Int64 {
            items.reduce(0) { $0 + $1.allocatedBytes }
        }
    }

    public let groups: [Group]
    public let preservedPaths: [URL]
    public let unreadableCount: Int

    let applicationRoots: [URL]
    let allowedRelatedRoots: [URL]

    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }

    func items(
        for bundleIdentifiers: Set<String>,
        itemPaths: Set<String>? = nil
    ) -> [AppUninstallPlan.Item] {
        groups
            .filter { bundleIdentifiers.contains($0.bundleIdentifier) }
            .flatMap(\.items)
            .filter { itemPaths?.contains($0.id) ?? true }
    }
}

/// Finds exact bundle-owned paths that have no installed application owner.
///
/// An identifier becomes a candidate only on **positive evidence that an
/// application once owned it**: a path in a location macOS creates for
/// applications and nothing else — a sandbox container, an application-scripts
/// folder, saved window state, WebKit storage, HTTP storage — or an entry in the
/// curated app-data table. A name that merely parses as reverse-DNS is not
/// evidence. `/Library/Preferences/org.cups.printers.plist` is the user's printer
/// configuration; `org.swift.swiftpm` is a build tool's cache. Both are shaped like
/// bundle identifiers, neither ever belonged to an application, and an earlier
/// version of this rule offered the printer configuration as "safe to delete".
/// Once an identifier is established, its preferences, caches and launch items
/// are collected as leftovers — but never as the reason it was believed to be one.
public struct OrphanedAppLeftoverPlanner: Sendable {

    /// The identifiers with application evidence, and the roots that could not be
    /// read while looking. Computed once per scan and handed to both the owner
    /// resolution and `plan`, so the two cannot disagree about which identifiers
    /// were examined.
    public struct CandidateScan: Sendable, Equatable {
        public let identifiers: Set<String>
        public let unreadableCount: Int
        /// Containers named by a UUID, under the identifier macOS wrote inside each
        /// — see `uuidNamedContainers`. Paths, since `URL` is compared with its
        /// trailing slash.
        public let uuidNamedContainers: [String: [String]]
        /// Group containers whose name begins with a Team ID, under the identifier
        /// that follows it — see `teamGroupContainers`.
        public let teamGroupContainers: [String: [TeamGroupContainer]]

        public struct TeamGroupContainer: Sendable, Equatable {
            public let path: String
            public let team: String
        }

        public init(
            identifiers: Set<String>, unreadableCount: Int,
            uuidNamedContainers: [String: [String]] = [:],
            teamGroupContainers: [String: [TeamGroupContainer]] = [:]
        ) {
            self.identifiers = identifiers
            self.unreadableCount = unreadableCount
            self.uuidNamedContainers = uuidNamedContainers
            self.teamGroupContainers = teamGroupContainers
        }
    }
    enum CandidatePathStatus: Sendable {
        case present
        case missing
        case unreadable
    }

    private let pathPlanner: AppUninstallPlanner
    private let directoryNames: @Sendable (URL) throws -> [String]
    private let candidatePathStatus: @Sendable (URL) -> CandidatePathStatus
    /// The Team ID an application bundle is signed by, or nil.
    private let teamIdentifier: @Sendable (URL) -> String?

    public init() {
        pathPlanner = AppUninstallPlanner()
        directoryNames = { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        candidatePathStatus = Self.pathStatus
        teamIdentifier = Self.signingTeam(of:)
    }

    init(
        pathPlanner: AppUninstallPlanner,
        directoryNames: @escaping @Sendable (URL) throws -> [String] = { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        candidatePathStatus: @escaping @Sendable (URL) -> CandidatePathStatus = Self.pathStatus,
        teamIdentifier: @escaping @Sendable (URL) -> String? = Self.signingTeam(of:)
    ) {
        self.pathPlanner = pathPlanner
        self.directoryNames = directoryNames
        self.candidatePathStatus = candidatePathStatus
        self.teamIdentifier = teamIdentifier
    }

    /// - Parameter candidates: the scan the caller already ran to resolve owners.
    ///   When nil, the planner scans itself — the headless path.
    public func plan(
        context: ScanContext = ScanContext(),
        registeredApplicationBundleIdentifiers: Set<String> = [],
        candidates: CandidateScan? = nil
    ) async throws -> OrphanedAppLeftoverPlan {
        let fileManager = FileManager.default
        var installed = AppUninstallPlanner.installedBundleIdentifiers(
            in: pathPlanner.applicationRoots, fileManager: fileManager
        )
        installed.formUnion(registeredApplicationBundleIdentifiers)
        let candidateScan = candidates ?? candidateBundleIdentifierScan(fileManager: fileManager)
        let identifiers = candidateScan.identifiers.filter {
            !AppUninstallPlanner.isProtectedBundleIdentifier($0)
                && !pathPlanner.protectedBundleIdentifiers.contains($0)
                && !AppUninstallPlanner.ownerIsInstalled(
                    $0, installedBundleIdentifiers: installed
                )
        }

        var candidates = pathPlanner.candidates(for: Set(identifiers))
        // A container the identifier's own name does not lead to. It goes through
        // everything below as any other candidate does: the allowed roots, the
        // exclusions, the protected patterns, and at removal the owner and identity
        // checks again.
        // Asked only when there is a group container to ask about: reading forty
        // signatures is quick, and still not free.
        let teamContainers = identifiers.sorted().flatMap { identifier in
            (candidateScan.teamGroupContainers[identifier] ?? []).map { (identifier, $0) }
        }
        if !teamContainers.isEmpty {
            let installedTeams = Set(
                AppUninstallPlanner.installedApplications(
                    in: pathPlanner.applicationRoots, fileManager: fileManager
                ).compactMap(teamIdentifier)
            )
            for (identifier, container) in teamContainers
            where !installedTeams.contains(container.team) {
                candidates.append(AppUninstallPlanner.Candidate(
                    url: URL(fileURLWithPath: container.path, isDirectory: true),
                    category: .containers,
                    content: .userData,
                    ownerBundleIdentifier: identifier
                ))
            }
        }
        for identifier in identifiers.sorted() {
            for path in candidateScan.uuidNamedContainers[identifier] ?? [] {
                candidates.append(AppUninstallPlanner.Candidate(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    category: .containers,
                    content: .userData,
                    ownerBundleIdentifier: identifier
                ))
            }
        }
        for identifier in identifiers.sorted() {
            guard let curation = ApplicationsScanner.curations[identifier] else { continue }
            candidates.append(AppUninstallPlanner.Candidate(
                url: pathPlanner.home.appendingPathComponent(curation.root),
                category: .support,
                content: .userData,
                ownerBundleIdentifier: identifier
            ))
        }

        var itemsByIdentifier: [String: [AppUninstallPlan.Item]] = [:]
        var preserved: [URL] = []
        var claimedPaths = Set<String>()
        var unreadableCount = candidateScan.unreadableCount

        for candidate in candidates {
            try Task.checkCancellation()
            let url = candidate.url.standardizedFileURL
            guard claimedPaths.insert(url.path).inserted else { continue }
            switch candidatePathStatus(url) {
            case .present:
                break
            case .missing:
                continue
            case .unreadable:
                unreadableCount += 1
                continue
            }

            guard pathPlanner.candidateIsSafe(url), !context.isExcluded(url) else {
                preserved.append(url)
                continue
            }

            let measurement = try await context.measurer.measure(url)
            unreadableCount += measurement.unreadableCount
            guard measurement.allocatedBytes > 0 else { continue }
            guard !measurement.containsProtectedPattern else {
                preserved.append(url)
                continue
            }

            let item = AppUninstallPlan.Item(
                url: url,
                category: candidate.category,
                content: candidate.content,
                allocatedBytes: measurement.allocatedBytes,
                ownerBundleIdentifier: candidate.ownerBundleIdentifier
            )
            itemsByIdentifier[candidate.ownerBundleIdentifier, default: []].append(item)
        }

        let categoryRank = Dictionary(
            uniqueKeysWithValues: AppUninstallPlan.Item.Category.allCases.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let groups = itemsByIdentifier.map { identifier, unsortedItems in
            let items = unsortedItems.sorted { left, right in
                let leftRank = categoryRank[left.category, default: 0]
                let rightRank = categoryRank[right.category, default: 0]
                if leftRank != rightRank { return leftRank < rightRank }
                if left.allocatedBytes != right.allocatedBytes {
                    return left.allocatedBytes > right.allocatedBytes
                }
                return left.url.path.localizedStandardCompare(right.url.path)
                    == .orderedAscending
            }
            return OrphanedAppLeftoverPlan.Group(
                bundleIdentifier: identifier, items: items
            )
        }.sorted { left, right in
            if left.totalBytes != right.totalBytes { return left.totalBytes > right.totalBytes }
            return left.bundleIdentifier.localizedStandardCompare(right.bundleIdentifier)
                == .orderedAscending
        }

        return OrphanedAppLeftoverPlan(
            groups: groups,
            preservedPaths: deduplicated(preserved),
            unreadableCount: unreadableCount,
            applicationRoots: pathPlanner.applicationRoots,
            allowedRelatedRoots: pathPlanner.allowedRelatedRoots
        )
    }

    /// Distinguishes an absent path from a path that macOS keeps private.
    /// `fileExists` returns false for both states and previously hid denied rows.
    private static func pathStatus(_ url: URL) -> CandidatePathStatus {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        guard result != 0 else { return .present }
        return switch errno {
        case ENOENT, ENOTDIR:
            .missing
        default:
            .unreadable
        }
    }

    /// Returns identifiers with application evidence — see the type note.
    public func candidateBundleIdentifiers() -> Set<String> {
        scanCandidates().identifiers
    }

    /// The candidate scan, for callers that also resolve owners and must hand the
    /// same set to `plan`.
    public func scanCandidates() -> CandidateScan {
        candidateBundleIdentifierScan(fileManager: .default)
    }

    /// Resolves which candidates belong to an installed application, walking each
    /// identifier up its hierarchy: `com.vendor.app.helper` is owned by
    /// `com.vendor.app` when that application exists. Shared by the app (which
    /// asks NSWorkspace) and the CLI (which asks Launch Services directly), so the
    /// two cannot drift apart in what they protect.
    ///
    /// - Parameters:
    ///   - running: identifiers of applications with a live process — ground truth.
    ///   - isInstalled: whether Launch Services resolves the identifier to an
    ///     application that exists on disk.
    public static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>,
        running: Set<String>,
        isInstalled: (String) -> Bool
    ) -> Set<String> {
        var result = running
        for candidate in candidates {
            var parts = candidate.split(separator: ".").map(String.init)
            while parts.count >= 3 {
                let identifier = parts.joined(separator: ".")
                if isInstalled(identifier) {
                    result.insert(identifier)
                    break
                }
                parts.removeLast()
            }
        }
        return result
    }

    /// Finds identifiers only in locations that exist for applications alone.
    ///
    /// Deliberately not consulted: `Preferences`, `Caches`, `Logs`,
    /// `Application Support`, the dot-directories, the temp and cache
    /// directories, and every system-library root. Daemons, command-line tools
    /// and licensing schemes all write reverse-DNS names there, and none of them
    /// is an application. Those paths are still *collected* for an identifier
    /// that qualifies — `candidates(for:)` probes every location — they just
    /// cannot be the reason it qualifies.
    private func candidateBundleIdentifierScan(fileManager: FileManager) -> CandidateScan {
        var result = Set<String>()
        var unreadableCount = 0

        func names(in root: URL) -> [String] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return [] }
            do {
                return try directoryNames(root)
            } catch {
                unreadableCount += 1
                return []
            }
        }

        func addDirectNames(
            in root: URL, skippingSuffix skipped: String? = nil, listed: [String]? = nil
        ) {
            for name in listed ?? names(in: root) {
                // A `<id>.binarycookies` file is claimed by the suffix pass below;
                // taking it whole here manufactured `<id>.binarycookies` as a
                // second, phantom identifier.
                if let skipped, name.hasSuffix(skipped) { continue }
                if let identifier = AppUninstallPlanner.verifiedBundleIdentifier(name) {
                    result.insert(identifier)
                }
            }
        }

        func addNames(in root: URL, removing suffix: String) {
            for name in names(in: root) where name.hasSuffix(suffix) {
                let raw = String(name.dropLast(suffix.count))
                if let identifier = AppUninstallPlanner.verifiedBundleIdentifier(raw) {
                    result.insert(identifier)
                }
            }
        }

        let userLibrary = pathPlanner.userLibrary
        // Each of these is created by macOS for an application and for nothing
        // else. A daemon has no sandbox container, no application scripts and no
        // saved window state; a command-line tool has no WebKit storage.
        // Listed once: the same names are read again below for the UUID-named
        // containers, and a folder that cannot be read is one gap, not two.
        let containersRoot = userLibrary.appendingPathComponent("Containers")
        let containerNames = names(in: containersRoot)
        addDirectNames(in: containersRoot, listed: containerNames)
        for relative in ["Application Scripts", "WebKit"] {
            addDirectNames(in: userLibrary.appendingPathComponent(relative))
        }
        addDirectNames(
            in: userLibrary.appendingPathComponent("HTTPStorages"),
            skippingSuffix: ".binarycookies"
        )
        addNames(
            in: userLibrary.appendingPathComponent("HTTPStorages"),
            removing: ".binarycookies"
        )
        addNames(
            in: userLibrary.appendingPathComponent("Saved Application State"),
            removing: ".savedState"
        )

        let uuidNamed = Self.uuidNamedContainers(in: containersRoot, names: containerNames)
        result.formUnion(uuidNamed.keys)

        let groupsRoot = userLibrary.appendingPathComponent("Group Containers")
        let teamGroups = Self.teamGroupContainers(in: groupsRoot, names: names(in: groupsRoot))
        result.formUnion(teamGroups.keys)

        // The curated table is a hand-verified claim that an application owns
        // this root — evidence of the strongest kind.
        for (identifier, curation) in ApplicationsScanner.curations {
            let root = pathPlanner.home.appendingPathComponent(curation.root)
            if fileManager.fileExists(atPath: root.path) { result.insert(identifier) }
        }

        return CandidateScan(
            identifiers: result, unreadableCount: unreadableCount,
            uuidNamedContainers: uuidNamed,
            teamGroupContainers: teamGroups
        )
    }

    /// Group containers named `<Team ID>.<identifier>`, keyed by that identifier.
    ///
    /// Group containers were never offered, for a sound reason: the name is
    /// whatever the developer chose, so it cannot be matched to a bundle identifier.
    /// Surfshark is `com.surfshark.vpnclient.macos.direct` and keeps its group at
    /// `YHUG37CKN8.com.surfshark.vpn.direct`; WorkingHours is
    /// `mac.partl.workinghours` with a group at `P9337B87X7.partl.workinghours`.
    /// Matching by name, Purge offered both — a working VPN's configuration — as
    /// leftovers, along with Adobe's and Rhino's, on the owner's Mac on 20 Sep 2026.
    ///
    /// What the name does carry is the **Team ID**, ten characters before the first
    /// dot, and every installed application is signed by one. So the owner test for
    /// a group container is not about its name at all: it is a leftover only when
    /// **no installed application is signed by that team**. On that Mac the rule
    /// kept Surfshark's, WorkingHours', Adobe's and all five of Microsoft's (Visual
    /// Studio Code is signed by the same team as `com.microsoft.oneauth`, and
    /// nothing here can tell whose the container is), and found Raycast's, whose
    /// team signs nothing that is installed.
    ///
    /// A `group.<name>` container carries no team and is still never offered. The
    /// part after the team has to be an identifier — `22MMUN2RN5.lv` is not an
    /// application's name — and Apple's are refused like any other of Apple's.
    static func teamGroupContainers(
        in groups: URL, names: [String]
    ) -> [String: [CandidateScan.TeamGroupContainer]] {
        var found: [String: [CandidateScan.TeamGroupContainer]] = [:]
        for name in names.sorted() {
            guard let dot = name.firstIndex(of: "."), name.distance(from: name.startIndex, to: dot) == 10
            else { continue }
            let team = String(name[..<dot])
            guard team.unicodeScalars.allSatisfy({
                ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
            }), let identifier = AppUninstallPlanner.verifiedBundleIdentifier(
                String(name[name.index(after: dot)...])
            ) else { continue }
            found[identifier, default: []].append(CandidateScan.TeamGroupContainer(
                path: groups.appendingPathComponent(name, isDirectory: true).standardizedFileURL.path,
                team: team
            ))
        }
        return found
    }

    /// The Team ID a bundle is signed by, read from its signature without
    /// validating it: the question is whose it says it is, not whether it is intact.
    @Sendable static func signingTeam(of application: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Containers whose folder is a UUID, keyed by the identifier inside them.
    ///
    /// An application that came from iOS, or was built with Catalyst, is given a
    /// container at `~/Library/Containers/<UUID>`. The name says nothing, so a
    /// classifier that reads identifiers off folder names walks past it: 57 MB of a
    /// removed PokerStars on the owner's Mac on 20 Sep 2026. macOS records whose it
    /// is in `.com.apple.containermanagerd.metadata.plist`, under
    /// `MCMMetadataIdentifier`, inside every container it creates. That is the
    /// system's own word, and a container is already positive evidence of an
    /// application, so the identifier qualifies like any other found here — and
    /// then has to pass the same tests: not Apple's, no installed owner by bundle or
    /// by Launch Services, and an extension (`….NotificationExt`) answers to the
    /// application it is named beneath.
    ///
    /// A container with no readable record is left alone. Purge
    /// (github.com/jithin-sabu/purge-app) reads the same file, which is how it names
    /// this row; six of the eleven leftovers it listed beside it belonged to
    /// installed applications, which is what the owner tests are for.
    ///
    /// Not read from the shell that wrote this: it has no Full Disk Access, and a
    /// container's contents are closed to it. Verified in the app.
    static func uuidNamedContainers(
        in containers: URL, names: [String]
    ) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for name in names.sorted() where UUID(uuidString: name) != nil {
            let folder = containers.appendingPathComponent(name, isDirectory: true)
            let record = folder.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard let data = try? Data(contentsOf: record),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let raw = plist["MCMMetadataIdentifier"] as? String,
                  let identifier = AppUninstallPlanner.verifiedBundleIdentifier(raw)
            else { continue }
            found[identifier, default: []].append(folder.standardizedFileURL.path)
        }
        return found
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

extension OrphanedAppLeftoverPlan {
    static func removalIsStillSafe(
        _ item: AppUninstallPlan.Item,
        in plan: OrphanedAppLeftoverPlan,
        installedBundleIdentifiers: Set<String>
    ) -> Bool {
        guard plan.groups.contains(where: { $0.items.contains(item) }),
              let owner = item.ownerBundleIdentifier,
              !AppUninstallPlanner.ownerIsInstalled(
                  owner, installedBundleIdentifiers: installedBundleIdentifiers
              )
        else { return false }

        if let currentIdentity = FileIdentity.of(item.url),
           currentIdentity != item.plannedIdentity {
            return false
        }
        guard let root = plan.allowedRelatedRoots.first(where: {
            AppUninstallPlanner.isInside(item.url, root: $0)
        }), !AppUninstallPlanner.isSymbolicLink(item.url) else { return false }
        return !AppUninstallPlanner.hasSymbolicLinkInParents(of: item.url, through: root)
    }
}
