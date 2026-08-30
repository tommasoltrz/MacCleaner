import Foundation
import Testing
@testable import ScoloCore

/// Regressions from the August 2026 external review: exclusions must protect
/// ancestors, safety is judged per entry, Put Back matches real Trash paths, and
/// the follow-symlinks option follows symlinks.
@Suite("Review findings stay fixed")
struct ReviewFindingsTests {

    // MARK: - Exclusions

    @Test("an ancestor of an exclusion is not removable")
    func ancestorOfExclusionIsExcluded() {
        let context = ScanContext(excludedPaths: ["/Users/x/Documents/Project/Secrets"])
        // The folder that contains the exclusion: cleaning it would take the
        // secrets with it.
        #expect(context.isExcluded(URL(fileURLWithPath: "/Users/x/Documents/Project")))
        // The exclusion itself and its contents, as before.
        #expect(context.isExcluded(URL(fileURLWithPath: "/Users/x/Documents/Project/Secrets")))
        #expect(context.isExcluded(URL(fileURLWithPath: "/Users/x/Documents/Project/Secrets/key")))
        // A sibling is untouched.
        #expect(!context.isExcluded(URL(fileURLWithPath: "/Users/x/Documents/Other")))
    }

    @Test("a category root that merely contains an exclusion is still walked")
    func rootGateStaysNarrow() {
        let context = ScanContext(excludedPaths: ["/Users/x/Documents/Project/Secrets"])
        #expect(!context.isWithinExclusion(URL(fileURLWithPath: "/Users/x/Documents")))
        #expect(context.isWithinExclusion(
            URL(fileURLWithPath: "/Users/x/Documents/Project/Secrets/key")
        ))
    }

    // MARK: - Per-entry safety

    @Test("a non-regenerable entry in a safe category needs review")
    func archiveIsNotSafe() {
        let derived = FileEntry(
            url: URL(fileURLWithPath: "/tmp/DerivedData"), kind: .cache,
            allocatedBytes: 100, isRegenerable: true
        )
        let archive = FileEntry(
            url: URL(fileURLWithPath: "/tmp/App.xcarchive"), kind: .cache,
            allocatedBytes: 40, isRegenerable: false
        )
        let category = ScanCategoryResult(
            categoryID: .xcode, totalBytes: 140, entries: [derived, archive]
        )
        let results = ScanResults(categories: [category], startedAt: .now, finishedAt: .now)

        #expect(results.safeToRemoveBytes == 100)
        #expect(results.needsReviewBytes == 40)
    }

    // MARK: - Removal log format

    @Test("log lines round-trip the Trash destination and still read legacy lines")
    func removalLogRoundTrip() {
        let record = RemovalRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            originalPath: "/Users/x/Library/Caches/thing with spaces",
            bytes: 1234,
            disposition: .trashed,
            trashedPath: "/Users/x/.Trash/thing with spaces 2"
        )
        let parsed = RemovalLog.record(from: Substring(RemovalLog.line(for: record)))
        #expect(parsed == record)

        // A line written before the field existed parses with no destination.
        let legacy = "2026-08-01T00:00:00Z \"/Users/x/old\" 9 trashed"
        let old = RemovalLog.record(from: Substring(legacy))
        #expect(old?.originalPath == "/Users/x/old")
        #expect(old?.trashedPath == nil)
    }

    // MARK: - Pattern exclusions protect containers

    /// Two halves of one rule. `isExcluded` answers the cheap half — the match
    /// itself and anything inside it — with no walk. The expensive half, "this
    /// folder *contains* a match", is decided by the measurer during the traversal
    /// the scan is already paying for, and arrives as a flag on the measurement.
    @Test("a folder containing a pattern match is flagged by the measurement")
    func patternProtectsContainingFolder() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-pattern-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appendingPathComponent("Project/Deep")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(count: 16).write(to: project.appendingPathComponent("Vault.sparsebundle"))
        let sibling = base.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data(count: 16).write(to: sibling.appendingPathComponent("notes.txt"))

        let context = ScanContext(excludedPatterns: ["*.sparsebundle"])
        // A path *inside* a matching bundle: the cheap component check catches it.
        #expect(context.isExcluded(
            URL(fileURLWithPath: "/x/Vault.sparsebundle/bands/1a2b")
        ))
        // The container itself costs no walk here...
        #expect(!context.isExcluded(base.appendingPathComponent("Project")))
        // ...it is the measurement that knows, and the scanners refuse it.
        let flagged = try await context.measurer
            .measure(base.appendingPathComponent("Project"))
        #expect(flagged.containsProtectedPattern)
        let clean = try await context.measurer.measure(sibling)
        #expect(!clean.containsProtectedPattern)

        // `measureChildren` attributes the flag to the child that holds it.
        let children = try await context.measurer.measureChildren(of: base)
        let projectKey = try #require(
            children.keys.first { $0.lastPathComponent == "Project" }
        )
        let siblingKey = try #require(
            children.keys.first { $0.lastPathComponent == "Other" }
        )
        #expect(children[projectKey]?.containsProtectedPattern == true)
        #expect(children[siblingKey]?.containsProtectedPattern == false)
    }

    @Test("a scanner never emits a row whose tree holds a protected bundle")
    func scannerRefusesFlaggedTree() async throws {
        let developer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-flagged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: developer) }

        let guarded = developer.appendingPathComponent("Xcode/DerivedData/Guarded-abc/Build")
        try FileManager.default.createDirectory(at: guarded, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024)
            .write(to: guarded.appendingPathComponent("Secrets.keychain-db"))
        let ordinary = developer.appendingPathComponent("Xcode/DerivedData/Ordinary-def/Build")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: ordinary.appendingPathComponent("app.o"))

        let result = try await XcodeScanner(developerRoot: developer).scan(
            context: ScanContext(excludedPatterns: ["*.keychain-db"], protectRecentDays: 0)
        )
        #expect(!result.entries.contains { $0.url.lastPathComponent == "Guarded-abc" },
                "the project holds a keychain: cleaning the row would take it")
        #expect(result.entries.contains { $0.url.lastPathComponent == "Ordinary-def" })
    }

    // MARK: - Docker totals survive coordination

    @Test("filteringNoise leaves Docker's own accounting alone")
    func dockerTotalSurvivesNoiseFilter() {
        let row = FileEntry(
            url: URL(string: "docker://reclaimable/images")!,
            kind: .diskImage,
            allocatedBytes: 5_000_000_000,
            manualRemoval: FileEntry.ManualRemoval(
                explanation: "Docker's space", command: "docker image prune -a"
            )
        )
        let category = ScanCategoryResult(
            categoryID: .docker, totalBytes: 5_000_000_000, entries: [row]
        )
        let filtered = category.filteringNoise(below: 10_000_000)
        #expect(filtered.totalBytes == 5_000_000_000)
        #expect(filtered.entries.count == 1)
    }

    // MARK: - Xcode archives, on a real layout

    @Test("an archive date directory is never classified regenerable")
    func archiveLayoutNeedsReview() async throws {
        let developer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: developer) }
        let archive = developer.appendingPathComponent(
            "Xcode/Archives/2026-08-24/App 24-08-2026, 11.00.xcarchive/dSYMs"
        )
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: archive.appendingPathComponent("App.dSYM"))
        let derived = developer.appendingPathComponent("Xcode/DerivedData/App-abc")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: derived.appendingPathComponent("build.o"))

        let result = try await XcodeScanner(developerRoot: developer)
            .scan(context: ScanContext(protectRecentDays: 0))

        let archiveRow = try #require(result.entries.first { $0.url.path.contains("Archives") })
        let derivedRow = try #require(result.entries.first { $0.url.path.contains("DerivedData") })
        #expect(!archiveRow.isRegenerable,
                "the emitted row is the date directory, and it holds the only dSYMs")
        #expect(derivedRow.isRegenerable)
        #expect(result.safeToRemoveBytes < result.totalBytes)
    }

    // MARK: - Trash records are not durable identities

    /// A home with a Trash in it, thrown away when the test ends.
    private func trashSandbox() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true
        )
        return home
    }

    @Test("Put Back matches the trashed file's identity, not just its path")
    func putBackRequiresIdentity() async throws {
        let home = try trashSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let inTrash = home.appendingPathComponent(".Trash/Report.pdf")
        try Data(count: 2048).write(to: inTrash)
        let original = home.appendingPathComponent("Documents/Report.pdf")

        let log = RemovalLog(directory: home.appendingPathComponent("logs"))
        let identity = try #require(FileIdentity.of(inTrash))
        try log.append([RemovalRecord(
            timestamp: Date(), originalPath: original.path, bytes: 2048,
            disposition: .trashed, trashedPath: inTrash.path, trashedIdentity: identity
        )])

        let trash = TrashService(home: home, log: log)
        let item = try #require(try await trash.summary().items.first)
        #expect(item.canPutBack)
        try await trash.putBack(item)
        #expect(FileManager.default.fileExists(atPath: original.path))

        // A different file lands on the same Trash path. The record names an inode
        // that is gone, and the restore it once authorised is spent.
        try Data(count: 4096).write(to: inTrash)
        let stranger = try #require(try await TrashService(home: home, log: log)
            .summary().items.first)
        #expect(!stranger.canPutBack, "same path, different file — and the record is retired")
    }

    @Test("a record whose identity does not match is never offered")
    func mismatchedIdentityIsRefused() async throws {
        let home = try trashSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let inTrash = home.appendingPathComponent(".Trash/Budget.numbers")
        try Data(count: 1024).write(to: inTrash)

        let log = RemovalLog(directory: home.appendingPathComponent("logs"))
        // Right path, right moment, wrong file.
        try log.append([RemovalRecord(
            timestamp: Date(),
            originalPath: home.appendingPathComponent("Documents/Budget.numbers").path,
            bytes: 1024, disposition: .trashed,
            trashedPath: inTrash.path, trashedIdentity: "1:1"
        )])

        let trash = TrashService(home: home, log: log)
        let item = try #require(try await trash.summary().items.first)
        #expect(!item.canPutBack)
        await #expect(throws: TrashError.self) { try await trash.putBack(item) }
    }

    @Test("log lines round-trip the file identity, and legacy lines still parse")
    func identityRoundTrip() {
        let record = RemovalRecord(
            timestamp: Date(timeIntervalSince1970: 1_756_000_000),
            originalPath: "/Users/x/Library/Caches/thing with spaces",
            bytes: 12, disposition: .trashed,
            trashedPath: "/Users/x/.Trash/thing with spaces",
            trashedIdentity: "16777232:41231"
        )
        #expect(RemovalLog.record(from: Substring(RemovalLog.line(for: record))) == record)

        // Written before identities existed: parses, with no identity.
        let legacy = "2026-08-01T00:00:00Z \"/Users/x/old\" 9 trashed \"/Users/x/.Trash/old\""
        let old = RemovalLog.record(from: Substring(legacy))
        #expect(old?.trashedPath == "/Users/x/.Trash/old")
        #expect(old?.trashedIdentity == nil)
    }

    // MARK: - One arithmetic for tiles and lists

    @Test("a manual-removal category states the same figure in tile and list")
    func manualRemovalTotalsAgree() {
        let row = FileEntry(
            url: URL(string: "docker://reclaimable/images")!,
            displayName: "Images",
            kind: .diskImage,
            allocatedBytes: 5_000_000_000,
            manualRemoval: FileEntry.ManualRemoval(
                explanation: "Docker's space", command: "docker image prune -a"
            )
        )
        #expect(row.reclaimableBytes == 0, "this app frees nothing here")
        #expect(row.displayBytes == 5_000_000_000, "but the space is real and the row says so")

        let category = ScanCategoryResult(
            categoryID: .docker, totalBytes: 5_000_000_000, entries: [row]
        )
        let results = ScanResults(categories: [category], startedAt: .now, finishedAt: .now)
        // The tile and the list it opens sum the same way.
        #expect(results.needsReviewBytes == 5_000_000_000)
        #expect(category.entries.reduce(0) { $0 + $1.displayBytes } == results.needsReviewBytes)
    }

    // MARK: - Cleanup splits its outcome honestly

    @Test("permanent removals are counted as deleted, not trashed")
    func outcomeSplitsDispositions() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let victim = base.appendingPathComponent("cache.bin")
        try Data(count: 4096).write(to: victim)

        let outcome = try await CleanupService(
            log: RemovalLog(directory: base.appendingPathComponent("logs"))
        ).remove(
            entries: [FileEntry(url: victim, kind: .cache, allocatedBytes: 4096)],
            trashFirst: false
        )
        #expect(outcome.deletedCount == 1)
        #expect(outcome.trashedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    // MARK: - Process cancellation

    @Test("a cancelled caller does not wait out the child's timeout")
    func processCancellationKillsChild() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner().run("/bin/sleep", ["30"], timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10,
                "the child was killed, not awaited to its timeout")
    }

    // MARK: - Privileged Trash moves

    @Test("two items with one basename never plan the same Trash path")
    func privilegedMovesReserveDistinctPaths() throws {
        let trash = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-trashplan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trash) }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        // Something is already sitting on the obvious name.
        try Data(count: 4).write(to: trash.appendingPathComponent("Helper.app"))

        var reserved: Set<String> = []
        let first = CleanupService.freeTrashPath(
            for: URL(fileURLWithPath: "/Library/A/Helper.app"), in: trash, reserved: &reserved
        )
        let second = CleanupService.freeTrashPath(
            for: URL(fileURLWithPath: "/Library/B/Helper.app"), in: trash, reserved: &reserved
        )
        #expect(first.lastPathComponent == "Helper 2.app", "the plain name is taken on disk")
        #expect(second.lastPathComponent == "Helper 3.app", "and the first is now reserved")
        #expect(first != second)
    }

    // MARK: - Protected patterns reach an app's support folder

    @Test("an app whose support folder holds a keychain is not offered")
    func curatedSupportFolderProtectsTheApp() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-appdata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Fixture")
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Code Cache"), withIntermediateDirectories: true
        )
        try Data(count: 1024 * 1024)
            .write(to: support.appendingPathComponent("Code Cache/index"))
        try Data(count: 4096)
            .write(to: support.appendingPathComponent("Secrets.keychain-db"))

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "Fixture", home: home
        ))
        let curated = try #require(try await ApplicationsScanner.curatedChildren(
            curation, home: home,
            context: ScanContext(excludedPatterns: ["*.keychain-db"])
        ))
        #expect(curated.holdsProtectedContent)
        #expect(curated.entries.isEmpty, "nothing from this folder may be offered")
    }

    @Test("an explicit exclusion inside a support folder protects the app")
    func exclusionInSupportFolderProtectsTheApp() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-excl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Fixture")
        let secrets = support.appendingPathComponent("Vault/private")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: secrets.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Code Cache"), withIntermediateDirectories: true
        )
        try Data(count: 1024 * 1024)
            .write(to: support.appendingPathComponent("Code Cache/index"))

        let curation = try #require(ApplicationsScanner.curation(
            bundleID: nil, baseName: "Fixture", home: home
        ))
        // The user excluded a folder that lives inside the support folder but is
        // not one of the curated cache paths. It used to sit silently in the locked
        // remainder — which travels with the bundle.
        let curated = try #require(try await ApplicationsScanner.curatedChildren(
            curation, home: home,
            context: ScanContext(excludedPaths: [
                support.appendingPathComponent("Vault").standardizedFileURL.path
            ])
        ))
        #expect(curated.holdsProtectedContent)
        #expect(curated.entries.isEmpty)
    }

    @Test("a dangling symlink in the Trash does not look like a free name")
    func danglingLinkOccupiesItsName() throws {
        let trash = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-dangling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trash) }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        // A link to something that no longer exists: `fileExists` follows it and
        // reports nothing there, so `mv` would have replaced it.
        try FileManager.default.createSymbolicLink(
            atPath: trash.appendingPathComponent("Report.pdf").path,
            withDestinationPath: trash.appendingPathComponent("gone.pdf").path
        )
        #expect(!FileManager.default.fileExists(
            atPath: trash.appendingPathComponent("Report.pdf").path
        ), "sanity: this is exactly the check that used to be wrong")

        var reserved: Set<String> = []
        let chosen = CleanupService.freeTrashPath(
            for: URL(fileURLWithPath: "/Library/X/Report.pdf"), in: trash, reserved: &reserved
        )
        #expect(chosen.lastPathComponent == "Report 2.pdf")
    }

    // MARK: - Automatic scan policy

    @Test("never means never, whatever else is true")
    func cadenceNeverNeverRuns() {
        #expect(!AutomaticScanPolicy.isDue(.init(
            lastFinished: nil, cadence: .never
        )))
    }

    @Test("a library that has never been scanned is due at once")
    func neverScannedIsDue() {
        #expect(AutomaticScanPolicy.isDue(.init(lastFinished: nil, cadence: .daily)))
    }

    @Test("due only once the cadence has elapsed since the last scan finished")
    func dueAfterInterval() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let elevenHours = now.addingTimeInterval(-11 * 60 * 60)
        let twoDays = now.addingTimeInterval(-2 * 24 * 60 * 60)

        #expect(!AutomaticScanPolicy.isDue(.init(
            now: now, lastFinished: elevenHours, cadence: .daily
        )))
        #expect(AutomaticScanPolicy.isDue(.init(
            now: now, lastFinished: twoDays, cadence: .daily
        )))
        #expect(!AutomaticScanPolicy.isDue(.init(
            now: now, lastFinished: twoDays, cadence: .weekly
        )))
    }

    @Test("idle-only waits for both the power adapter and a quiet keyboard")
    func idleOnlyGating() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        func conditions(power: Bool, idle: TimeInterval) -> AutomaticScanPolicy.Conditions {
            .init(
                now: now, lastFinished: nil, cadence: .daily,
                requiresIdleAndPower: true, isOnACPower: power, secondsSinceUserInput: idle
            )
        }
        #expect(!AutomaticScanPolicy.isDue(conditions(power: false, idle: 3600)))
        #expect(!AutomaticScanPolicy.isDue(conditions(power: true, idle: 10)))
        #expect(AutomaticScanPolicy.isDue(
            conditions(power: true, idle: AutomaticScanPolicy.idleThreshold)
        ))
    }

    @Test("a scan already running is never joined by a second")
    func scanningBlocksTheScheduler() {
        #expect(!AutomaticScanPolicy.isDue(.init(
            lastFinished: nil, cadence: .daily, isScanning: true
        )))
    }

    @Test("a clock that jumped backwards does not park the schedule")
    func backwardsClockStillRuns() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        // The log says the last scan finished in the future.
        #expect(AutomaticScanPolicy.isDue(.init(
            now: now, lastFinished: now.addingTimeInterval(90_000), cadence: .daily
        )))
    }

    // MARK: - Identity of a link is the link

    @Test("a symlink is identified by itself, not by what it points at")
    func identityDoesNotFollowLinks() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("target.bin")
        try Data(count: 16).write(to: target)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let linkIdentity = try #require(FileIdentity.of(link))
        let targetIdentity = try #require(FileIdentity.of(target))
        #expect(linkIdentity != targetIdentity, "a replacement link would otherwise match")

        // A broken link still has an identity, where `stat` would have given none.
        let broken = base.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            atPath: broken.path, withDestinationPath: base.appendingPathComponent("gone").path
        )
        #expect(FileIdentity.of(broken) != nil)
    }

    // MARK: - A descendant holding stdout cannot hang the runner

    @Test("the runner returns when the child exits, not when its grandchild does")
    func descendantHoldingStdoutDoesNotHang() async throws {
        let started = Date()
        // `sh` exits at once; the backgrounded `sleep` inherits stdout and keeps
        // the pipe open behind it. Reading to end first waited for the sleep.
        let data = try await ProcessRunner().run(
            "/bin/sh", ["-c", "sleep 20 & echo done"], timeout: .seconds(60)
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(String(decoding: data, as: UTF8.self).contains("done"))
        #expect(elapsed < 10, "took \(elapsed)s — the grandchild should not hold the runner")
    }

    // MARK: - Follow symlinks

    @Test("the follow-symlinks option actually follows them")
    func followSymlinksFollows() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024 * 1024)
            .write(to: outside.appendingPathComponent("payload.bin"))
        try Data(repeating: 0x41, count: 4096)
            .write(to: root.appendingPathComponent("local.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside
        )

        let ignoring = try await AllocatedSizeMeasurer().measure(root)
        #expect(ignoring.fileCount == 1, "off: the link is not descended")

        let following = try await AllocatedSizeMeasurer(followSymlinks: true).measure(root)
        #expect(following.fileCount == 2, "on: the target's file is counted")
        #expect(following.allocatedBytes > ignoring.allocatedBytes)
    }
}
