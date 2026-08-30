import Foundation

/// The libraries Photos, Music and TV own. Their contents are managed by those
/// apps — removing pieces of them corrupts the library, and Photos in particular
/// keeps its own Recently Deleted. The Documents scanner never lists them, and the
/// Storage Explorer locks them; ordinary document packages (Pages, Keynote,
/// `.rtfd`) are just files and are not on this list.
public enum AppleMediaLibrary {
    private static let extensions: Set<String> = [
        "photoslibrary", "aplibrary", "migratedphotolibrary", "musiclibrary", "tvlibrary",
    ]
    /// Folders that hold a library without a library extension.
    private static let homeRelativePaths: Set<String> = [
        "Music/Music", "Music/iTunes", "Movies/TV",
    ]

    public static func contains(_ url: URL, home: URL) -> Bool {
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return false }
        return homeRelativePaths.contains(String(path.dropFirst(homePath.count + 1)))
    }
}
