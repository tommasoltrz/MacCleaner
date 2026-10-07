import Foundation

/// Product identity and compatibility with data from the previous app name.
public enum AppIdentity {
    public static let name = "Moppo"
    public static let bundleIdentifier = "com.tommasolaterza.Moppo"

    // Keep these values to read existing settings and move existing data.
    static let legacyName = "Scolo"
    static let legacyBundleIdentifier = "com.tommasolaterza.Scolo"
    private static let preferencesMigrationKey = "moppo.didMigrateLegacyPreferences"

    /// Copies existing preferences once without replacing current values.
    public static func migratePreferences(
        in defaults: UserDefaults = .standard,
        from legacyDomain: String? = nil
    ) {
        guard !defaults.bool(forKey: preferencesMigrationKey) else { return }
        for (key, value) in defaults.persistentDomain(forName: legacyDomain ?? legacyBundleIdentifier) ?? [:] {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: preferencesMigrationKey)
    }
}

/// Resolves app data folders and preserves data from the previous app name.
public enum AppStorage {
    public static var supportDirectory: URL {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return directory(in: parent)
    }

    public static var logDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return directory(in: library.appendingPathComponent("Logs", isDirectory: true))
    }

    /// Moves the old folder only when the new folder does not exist.
    static func directory(in parent: URL, fileManager: FileManager = .default) -> URL {
        let current = parent.appendingPathComponent(AppIdentity.name, isDirectory: true)
        let legacy = parent.appendingPathComponent(AppIdentity.legacyName, isDirectory: true)
        guard !fileManager.fileExists(atPath: current.path),
              fileManager.fileExists(atPath: legacy.path) else { return current }
        do {
            try fileManager.moveItem(at: legacy, to: current)
            return current
        } catch {
            // A concurrent process can complete the move first.
            if fileManager.fileExists(atPath: current.path) { return current }
            // Keep history available if the move fails. Try again on the next access.
            return legacy
        }
    }
}
