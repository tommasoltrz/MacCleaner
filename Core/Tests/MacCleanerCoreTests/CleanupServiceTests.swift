import Foundation
import Testing
@testable import MacCleanerCore

/// The same temporary-directory fixture the measurer tests use.
private typealias Sandbox = AllocatedSizeMeasurerTests.Sandbox

private let oneMB = 1024 * 1024

/// Removes a fixture from the user's real Trash.
///
/// Only the trashing test reaches the real `~/.Trash` — everything else runs against
/// a Trash inside its own sandbox — and even that one must not leave anything behind.
private func discardFromRealTrash(named name: String) {
    let trash = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".Trash", isDirectory: true)
        .appendingPathComponent(name)
    try? FileManager.default.removeItem(at: trash)
}

private func entry(_ url: URL, kind: FileEntry.Kind = .file, bytes: Int64 = 0) -> FileEntry {
    FileEntry(url: url, kind: kind, allocatedBytes: bytes)
}

@Suite("Cleanup")
struct CleanupServiceTests {

    @Test("trashing moves the file to ~/.Trash and reports the size it really freed")
    func trashingMovesToTheRealTrash() async throws {
        let sandbox = try Sandbox()
        let name = "maccleaner-trash-fixture-\(UUID().uuidString).bin"
        let fixture = try sandbox.writeFile(name, bytes: 3 * oneMB)
        defer { discardFromRealTrash(named: name) }

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        // `allocatedBytes: 0` stands in for a stale scan: the outcome must come from
        // measuring at removal time, not from the number the row was carrying.
        let outcome = try await CleanupService(log: log)
            .remove(entries: [entry(fixture)], trashFirst: true)

        #expect(outcome.removedCount == 1)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.freedBytes >= Int64(3 * oneMB))

        let trashed = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash").appendingPathComponent(name)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))

        let logged = try #require(log.recentEntries().first)
        #expect(logged.originalPath == fixture.path)
        #expect(logged.disposition == .trashed)
        #expect(logged.bytes == outcome.freedBytes)
    }

    @Test("one failure does not abort the batch and is named in `failed`")
    func failureDoesNotAbortTheBatch() async throws {
        let sandbox = try Sandbox()
        let first = try sandbox.writeFile("first.bin", bytes: oneMB)
        // A genuine refusal: the immutable flag makes removal fail with EPERM.
        // (A *missing* file is no longer a failure — see the test below.)
        let locked = try sandbox.writeFile("locked.bin", bytes: oneMB)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        }
        let last = try sandbox.writeFile("last.bin", bytes: oneMB)

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        // `privilegedFallback` stays at its default of false: a permission failure in
        // a test must fail, never raise an administrator password dialog.
        let outcome = try await CleanupService(log: log).remove(
            entries: [entry(first), entry(locked), entry(last)],
            trashFirst: false
        )

        #expect(outcome.removedCount == 2)
        #expect(outcome.failed == [locked.path])
        #expect(outcome.freedBytes >= Int64(2 * oneMB))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        // The entry after the failure was still removed.
        #expect(!FileManager.default.fileExists(atPath: last.path))
        // And only the successes were logged.
        #expect(log.recentEntries().count == 2)
    }

    @Test("an already-missing entry is not a failure")
    func alreadyMissingIsNotAFailure() async throws {
        // The scan table is a snapshot; the user can delete a file in Finder before
        // cleaning up here. The outcome they wanted has already happened, and
        // reporting it as a failure would keep a ghost row alive.
        let sandbox = try Sandbox()
        let missing = sandbox.root.appendingPathComponent("never-existed-\(UUID().uuidString).bin")
        let real = try sandbox.writeFile("real.bin", bytes: oneMB)

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        let outcome = try await CleanupService(log: log).remove(
            entries: [entry(missing), entry(real)],
            trashFirst: false
        )

        #expect(outcome.failed.isEmpty)
        #expect(outcome.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }

    /// Deliberately not run against a real `.app`: Applications always moves to the
    /// Trash, and a test that exercised that path would have to put fixtures in the
    /// user's Trash to prove it. The rule itself is asserted below instead.
    @Test("attached children are removed before the entry they belong to")
    func childrenGoFirst() async throws {
        let sandbox = try Sandbox()
        let parent = try sandbox.directory("Demo")
        try sandbox.writeFile("Demo/payload.bin", bytes: 2 * oneMB)
        let leftover = try sandbox.directory("Library/Caches/com.demo")
        try sandbox.writeFile("Library/Caches/com.demo/blob.bin", bytes: oneMB)

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        let group = FileEntry(
            url: parent,
            kind: .folder,
            allocatedBytes: 0,
            children: [entry(leftover, kind: .cache)]
        )
        let outcome = try await CleanupService(log: log).remove(entries: [group], trashFirst: false)

        #expect(outcome.removedCount == 2)
        #expect(outcome.freedBytes >= Int64(3 * oneMB))
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        // Newest first, so the parent — removed last — leads.
        let logged = log.recentEntries()
        #expect(logged.map(\.originalPath) == [parent.path, leftover.path])
    }

    @Test("an application moves to the Trash even with the setting off")
    func applicationsAlwaysMoveToTrash() {
        let app = entry(URL(fileURLWithPath: "/Applications/Demo.app"), kind: .appBundle)
        #expect(CleanupService.alwaysMovesToTrash(app))
        #expect(!CleanupService.alwaysMovesToTrash(entry(URL(fileURLWithPath: "/tmp/x.bin"))))
    }

    @Test("only an explicitly unlocked user-data row bypasses protection")
    func userDataRequiresItsExactOverride() {
        let userData = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo profiles"),
            kind: .folder,
            allocatedBytes: 1,
            protectionReason: .userData
        )
        let running = FileEntry(
            url: URL(fileURLWithPath: "/Applications/Demo.app"),
            kind: .appBundle,
            allocatedBytes: 1,
            protectionReason: .running
        )
        let toolManaged = FileEntry(
            url: URL(fileURLWithPath: "/tmp/runtime"),
            kind: .folder,
            allocatedBytes: 1,
            manualRemoval: .init(explanation: "Use its tool", command: "tool remove")
        )

        #expect(!CleanupService.removalAllowed(userData, userDataRemovalOverrides: []))
        #expect(!CleanupService.removalAllowed(
            userData, userDataRemovalOverrides: ["/tmp/somewhere-else"]
        ))
        #expect(CleanupService.removalAllowed(
            userData, userDataRemovalOverrides: [userData.id]
        ))
        // An override cannot turn a genuinely unavailable operation into a checkbox.
        #expect(!CleanupService.removalAllowed(
            running, userDataRemovalOverrides: [running.id]
        ))
        #expect(!CleanupService.removalAllowed(
            toolManaged, userDataRemovalOverrides: [toolManaged.id]
        ))
    }

    @Test("an unlocked user-data row always moves to the Trash")
    func userDataAlwaysMovesToTrash() {
        let userData = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo profiles"),
            kind: .folder,
            allocatedBytes: 1,
            protectionReason: .userData
        )
        #expect(CleanupService.alwaysMovesToTrash(userData))
    }

    @Test("removing an app preserves user data unless the parent is explicitly overridden")
    func appRemovalNeedsItsOwnOverrideForUserData() {
        let cache = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo cache"),
            kind: .cache,
            allocatedBytes: 10,
            isRegenerable: true
        )
        let profile = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo profile"),
            kind: .folder,
            allocatedBytes: 20,
            protectionReason: .userData
        )
        let runningChild = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo helper"),
            kind: .folder,
            allocatedBytes: 1,
            protectionReason: .running
        )
        let toolManagedChild = FileEntry(
            url: URL(fileURLWithPath: "/tmp/Demo managed data"),
            kind: .folder,
            allocatedBytes: 1,
            manualRemoval: .init(explanation: "Use its tool", command: "tool remove")
        )
        let app = FileEntry(
            url: URL(fileURLWithPath: "/Applications/Demo.app"),
            kind: .appBundle,
            allocatedBytes: 30,
            children: [cache, profile, runningChild, toolManagedChild]
        )

        #expect(CleanupService.removalTargets(
            for: app, removeProtectedAppData: false
        ).map(\.id) == [cache.id, app.id])
        #expect(CleanupService.removalTargets(
            for: app, removeProtectedAppData: true
        ).map(\.id) == [cache.id, profile.id, app.id])
    }

    @Test("a cancelled cleanup stops between entries")
    func cancellationStopsTheBatch() async throws {
        let sandbox = try Sandbox()
        var entries: [FileEntry] = []
        for index in 0..<500 {
            entries.append(entry(try sandbox.writeFile("bulk/file-\(index).bin", bytes: 1024)))
        }
        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))

        let task = Task { [entries] in
            try await CleanupService(log: log).remove(entries: entries, trashFirst: false)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let survivors = try FileManager.default.contentsOfDirectory(
            atPath: sandbox.root.appendingPathComponent("bulk").path
        )
        #expect(!survivors.isEmpty, "cancellation must stop the batch, not merely mark it")
    }
}

@Suite("Removal log")
struct RemovalLogTests {

    @Test("a path containing spaces round-trips")
    func spacesRoundTrip() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        let awkward = "/Users/someone/Downloads/My Big Backup (v2)/final report 3.zip"

        try log.append(entries: [entry(URL(fileURLWithPath: awkward), bytes: 4096)],
                       disposition: .deleted)

        let record = try #require(log.recentEntries().first)
        #expect(record.originalPath == awkward)
        #expect(record.bytes == 4096)
        #expect(record.disposition == .deleted)
        #expect(log.logFileURL.lastPathComponent == "removals.log")
    }

    /// Quotes, backslashes and newlines are all legal in a macOS file name, and any
    /// one of them naively written would either break the field or the line.
    @Test("quotes, backslashes and newlines in a path survive the log")
    func hostilePathsRoundTrip() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        let paths = [
            #"/Users/someone/Desktop/a "quoted" name.txt"#,
            #"/Users/someone/Desktop/back\slash \ here.txt"#,
            "/Users/someone/Desktop/two\nlines.txt",
            "/Users/someone/Desktop/plain.txt"
        ]

        try log.append(entries: paths.map { entry(URL(fileURLWithPath: $0), bytes: 1) },
                       disposition: .trashed)

        // Newest first, so the file's order reversed.
        #expect(log.recentEntries().map(\.originalPath) == paths.reversed())
    }

    @Test("appending is additive and reading is newest first")
    func appendsAccumulate() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)

        try log.append(entries: [entry(URL(fileURLWithPath: "/tmp/one"), bytes: 1)],
                       disposition: .deleted)
        try log.append(entries: [entry(URL(fileURLWithPath: "/tmp/two"), bytes: 2)],
                       disposition: .trashed)

        #expect(log.recentEntries().map(\.originalPath) == ["/tmp/two", "/tmp/one"])
        #expect(log.recentEntries(limit: 1).map(\.originalPath) == ["/tmp/two"])
    }

    @Test("a truncated last line costs only itself")
    func truncatedLineIsSkipped() throws {
        let sandbox = try Sandbox()
        let log = RemovalLog(directory: sandbox.root)
        try log.append(entries: [entry(URL(fileURLWithPath: "/tmp/kept"), bytes: 8)],
                       disposition: .deleted)

        let handle = try FileHandle(forWritingTo: log.logFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"2026-08-18T09:41:07Z "/tmp/half"#.utf8))
        try handle.close()

        #expect(log.recentEntries().map(\.originalPath) == ["/tmp/kept"])
    }

    @Test("no log file yet reads as no history, not a failure")
    func missingLogIsEmpty() throws {
        let sandbox = try Sandbox()
        #expect(RemovalLog(directory: sandbox.root).recentEntries().isEmpty)
    }
}

@Suite("Trash")
struct TrashServiceTests {

    /// A Trash of the test's own, so nothing here can touch the user's.
    private func makeTrash(_ sandbox: Sandbox) throws -> URL {
        try sandbox.directory("home/.Trash")
    }

    private func service(_ sandbox: Sandbox, log: RemovalLog? = nil) -> TrashService {
        TrashService(
            home: sandbox.root.appendingPathComponent("home"),
            log: log ?? RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        )
    }

    @Test("Put Back is refused for an item MacCleaner did not trash")
    func putBackRefusedWithoutALogEntry() async throws {
        let sandbox = try Sandbox()
        _ = try makeTrash(sandbox)
        try sandbox.writeFile("home/.Trash/Dragged In By Finder.zip", bytes: 2 * oneMB)

        let trash = service(sandbox)
        let summary = try await trash.summary()
        let item = try #require(summary.items.first)

        #expect(summary.itemCount == 1)
        #expect(item.name == "Dragged In By Finder.zip")
        #expect(item.bytes >= Int64(2 * oneMB))
        // Finder owns this one: nothing records where it came from.
        #expect(item.canPutBack == false)

        await #expect(throws: TrashError.putBackUnavailable(item.id)) {
            try await trash.putBack(item)
        }
        // Refusing left it where it was.
        #expect(FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test("Put Back restores an item this app trashed to its logged path")
    func putBackRestoresALoggedItem() async throws {
        let sandbox = try Sandbox()
        _ = try makeTrash(sandbox)
        let inTrash = try sandbox.writeFile("home/.Trash/Old Notes 2019.rtf", bytes: oneMB)
        let original = sandbox.root.appendingPathComponent("home/Documents/Old Notes 2019.rtf")

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        // As the app logs it: the destination `trashItem` reported, plus the
        // file's identity. Put Back matches on the identity, never on the name.
        try log.append([RemovalRecord(
            timestamp: Date(), originalPath: original.path, bytes: Int64(oneMB),
            disposition: .trashed, trashedPath: inTrash.path,
            trashedIdentity: FileIdentity.of(inTrash)
        )])

        let trash = service(sandbox, log: log)
        let item = try #require(try await trash.summary().items.first)
        #expect(item.canPutBack)

        try await trash.putBack(item)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: inTrash.path))
    }

    @Test("Put Back refuses to overwrite whatever is at the original path now")
    func putBackRefusesToOverwrite() async throws {
        let sandbox = try Sandbox()
        _ = try makeTrash(sandbox)
        let inTrash = try sandbox.writeFile("home/.Trash/Budget 2026.numbers", bytes: oneMB)
        let original = try sandbox.writeFile("home/Documents/Budget 2026.numbers", bytes: 64)

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        try log.append([RemovalRecord(
            timestamp: Date(), originalPath: original.path, bytes: Int64(oneMB),
            disposition: .trashed, trashedPath: inTrash.path,
            trashedIdentity: FileIdentity.of(inTrash)
        )])

        let trash = service(sandbox, log: log)
        let item = try #require(try await trash.summary().items.first)

        await #expect(throws: TrashError.destinationOccupied(original.path)) {
            try await trash.putBack(item)
        }
        // The newer file at the destination is untouched.
        let bytes = try #require(
            (try? original.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        )
        #expect(bytes == 64)
    }

    @Test("a `deleted` log entry is never offered as a restore target")
    func deletedRemovalsAreNotRestorable() async throws {
        let sandbox = try Sandbox()
        _ = try makeTrash(sandbox)
        try sandbox.writeFile("home/.Trash/vanished.log", bytes: oneMB)
        let original = sandbox.root.appendingPathComponent("home/Library/Logs/vanished.log")

        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("logs"))
        try log.append(entries: [entry(original, bytes: Int64(oneMB))], disposition: .deleted)

        let item = try #require(try await service(sandbox, log: log).summary().items.first)
        #expect(item.canPutBack == false)
    }

    @Test("the totals cover the whole Trash while the rows are capped, largest first")
    func totalsCoverEverythingTheRowsDoNot() async throws {
        let sandbox = try Sandbox()
        _ = try makeTrash(sandbox)
        try sandbox.writeFile("home/.Trash/small.bin", bytes: oneMB)
        try sandbox.writeFile("home/.Trash/medium.bin", bytes: 3 * oneMB)
        try sandbox.writeFile("home/.Trash/large.bin", bytes: 5 * oneMB)

        let summary = try await service(sandbox).summary(limit: 2)

        #expect(summary.itemCount == 3)
        #expect(summary.totalBytes >= Int64(9 * oneMB))
        #expect(summary.items.map(\.name) == ["large.bin", "medium.bin"])
        #expect(summary.items[0].deletedAt != nil)
    }

    @Test("emptying removes the contents and keeps the folder")
    func emptyingKeepsTheFolder() async throws {
        let sandbox = try Sandbox()
        let trashURL = try makeTrash(sandbox)
        try sandbox.writeFile("home/.Trash/one.bin", bytes: 2 * oneMB)
        try sandbox.writeFile("home/.Trash/folder/two.bin", bytes: 2 * oneMB)

        let freed = try await service(sandbox).empty().freedBytes

        let remaining = try FileManager.default.contentsOfDirectory(atPath: trashURL.path)
        #expect(freed >= Int64(4 * oneMB))
        #expect(FileManager.default.fileExists(atPath: trashURL.path))
        #expect(remaining.isEmpty)
    }

    @Test("an absent Trash summarises as empty rather than throwing")
    func missingTrashIsEmpty() async throws {
        let sandbox = try Sandbox()
        let summary = try await service(sandbox).summary()
        #expect(summary == TrashSummary())
    }
}
