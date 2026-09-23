import Foundation

/// Known shared data paths. Folder names alone do not establish ownership.
enum SharedApplicationData {
    static let epicLauncher = "com.epicgames.EpicGamesLauncher"

    struct Candidate: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case epicGame, epicLauncher }
        let root: URL
        let url: URL
        let kind: Kind
        let ownerIdentifiers: Set<String>

        var stagedApplicationRoot: URL? {
            kind == .epicLauncher ? url.appendingPathComponent("SelfUpdateStaging/Install") : nil
        }

        var displayName: String {
            kind == .epicLauncher ? "Unreal Engine launcher data" : url.lastPathComponent
        }

        func isSafe() -> Bool {
            guard Self.isDirectPath(url, root: root),
                  let currentOwners = SharedApplicationData.owners(at: url, kind: kind)
            else { return false }
            return currentOwners == ownerIdentifiers
        }

        static func isDirectPath(_ url: URL, root: URL) -> Bool {
            AppUninstallPlanner.isInside(url, root: root)
                && !AppUninstallPlanner.isSymbolicLink(url)
                && !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: root)
        }
    }

    static func discover(in root: URL) -> (candidates: [Candidate], unreadableCount: Int) {
        var candidates: [Candidate] = []
        var unreadable = 0
        let games = root.appendingPathComponent("Epic Games", isDirectory: true)
        if Candidate.isDirectPath(games, root: root), FileManager.default.fileExists(atPath: games.path) {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: games, includingPropertiesForKeys: [.isDirectoryKey], options: []
                )
                for child in children where Candidate.isDirectPath(child, root: root) {
                    if let identifiers = owners(at: child, kind: .epicGame) {
                        candidates.append(Candidate(root: root, url: child, kind: .epicGame, ownerIdentifiers: identifiers))
                    }
                }
            } catch { unreadable += 1 }
        }
        let launcher = root.appendingPathComponent("UnrealEngine/Launcher", isDirectory: true)
        if Candidate.isDirectPath(launcher, root: root),
           let identifiers = owners(at: launcher, kind: .epicLauncher) {
            candidates.append(Candidate(root: root, url: launcher, kind: .epicLauncher, ownerIdentifiers: identifiers))
        }
        return (candidates, unreadable)
    }

    private static func owners(at url: URL, kind: Candidate.Kind) -> Set<String>? {
        let manager = FileManager.default
        var identifiers: Set<String> = [epicLauncher]
        switch kind {
        case .epicGame:
            let marker = url.appendingPathComponent(".egstore", isDirectory: true)
            guard Candidate.isDirectPath(marker, root: url),
                  (try? marker.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let children = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { return nil }
            for bundle in children where bundle.pathExtension.lowercased() == "app" {
                guard Candidate.isDirectPath(bundle, root: url),
                      let identifier = AppUninstallPlanner.verifiedBundleIdentifier(Bundle(url: bundle)?.bundleIdentifier)
                else { return nil }
                identifiers.insert(identifier)
            }
        case .epicLauncher:
            let bundle = url.appendingPathComponent("SelfUpdateStaging/Install/Epic Games Launcher.app")
            guard Candidate.isDirectPath(bundle, root: url),
                  Bundle(url: bundle)?.bundleIdentifier == epicLauncher else { return nil }
        }
        return identifiers
    }
}
