import Foundation
import Testing
@testable import MoppoCore

@Suite("App identity migration")
struct AppIdentityTests {
    private final class Sandbox {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoppoMigration-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: parent) }

        var legacy: URL { parent.appendingPathComponent(AppIdentity.legacyName, isDirectory: true) }
        var current: URL { parent.appendingPathComponent(AppIdentity.name, isDirectory: true) }
    }

    @Test("Existing cleanup records keep their Put Back information")
    func removalRecordsSurvive() throws {
        let box = try Sandbox()
        let record = RemovalRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            originalPath: "/Users/test/Downloads/example.txt",
            bytes: 4096,
            disposition: .trashed,
            trashedPath: "/Users/test/.Trash/example.txt",
            trashedIdentity: "1:123",
            freedBytes: 4096
        )
        try RemovalLog(directory: box.legacy).append([record])

        let migrated = AppStorage.directory(in: box.parent)

        #expect(migrated == box.current)
        #expect(RemovalLog(directory: migrated).recentEntries() == [record])
        #expect(!FileManager.default.fileExists(atPath: box.legacy.path))

        try FileManager.default.removeItem(at: migrated)
        #expect(AppStorage.directory(in: box.parent) == box.current)
        #expect(!FileManager.default.fileExists(atPath: box.current.path))
    }

    @Test("Nested cache and history files move without changes")
    func nestedDataSurvives() throws {
        let box = try Sandbox()
        let history = box.legacy.appendingPathComponent("storage-history", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let payload = Data("saved measurement".utf8)
        try payload.write(to: history.appendingPathComponent("measurement.json"))
        try payload.write(to: box.legacy.appendingPathComponent("breakdown-cache.json"))

        let migrated = AppStorage.directory(in: box.parent)

        #expect(try Data(contentsOf: migrated.appendingPathComponent("storage-history/measurement.json")) == payload)
        #expect(try Data(contentsOf: migrated.appendingPathComponent("breakdown-cache.json")) == payload)
        #expect(AppStorage.directory(in: box.parent) == migrated)
    }

    @Test("An existing Moppo folder remains unchanged")
    func currentFolderWins() throws {
        let box = try Sandbox()
        for directory in [box.legacy, box.current] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("record"))
        }

        #expect(AppStorage.directory(in: box.parent) == box.current)
        #expect(try String(contentsOf: box.current.appendingPathComponent("record"), encoding: .utf8) == AppIdentity.name)
        #expect(try String(contentsOf: box.legacy.appendingPathComponent("record"), encoding: .utf8) == AppIdentity.legacyName)
    }

    @Test("Preferences migrate once and preserve current values")
    func preferencesMigrateOnce() throws {
        let suite = "MoppoMigration.\(UUID().uuidString)"
        let legacySuite = suite + ".previous"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: legacySuite)
        }
        defaults.setPersistentDomain([
            "settings.threshold": 20,
            "settings.exclusions": ["/Users/test/Keep"],
            "settings.automaticScan": false
        ], forName: legacySuite)
        defaults.set(30, forKey: "settings.threshold")

        AppIdentity.migratePreferences(in: defaults, from: legacySuite)

        #expect(defaults.integer(forKey: "settings.threshold") == 30)
        #expect(defaults.stringArray(forKey: "settings.exclusions") == ["/Users/test/Keep"])
        #expect(defaults.object(forKey: "settings.automaticScan") as? Bool == false)

        defaults.removeObject(forKey: "settings.exclusions")
        AppIdentity.migratePreferences(in: defaults, from: legacySuite)
        #expect(defaults.object(forKey: "settings.exclusions") == nil)
    }
}
