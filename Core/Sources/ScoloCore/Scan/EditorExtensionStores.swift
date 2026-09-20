import Foundation

/// Old extension versions that a VS Code–family editor has itself marked for
/// removal.
///
/// An editor keeps every extension in one folder, `~/.vscode/extensions`, as
/// `publisher.name-version[-platform]`. An update leaves the old version's folder
/// behind until the next start, and a start that never comes — an editor left open
/// for weeks, a removal that failed — leaves it for good.
///
/// **The editor's own record decides, never the version number.** Purge
/// (github.com/jithin-sabu/purge-app) groups the folders by name and keeps the
/// highest version, and two ordinary cases make that wrong:
///
/// * *A pinned older version.* "Install Another Version…" makes 1.0.0 the installed
///   one and marks 2.0.0 for removal. Keeping the highest deletes the one in use.
/// * *Profiles.* Each profile has its own `extensions.json` and all of them share
///   this folder. A version the default profile has moved past may be the one
///   another profile runs, so "not in `extensions.json`" is not evidence either.
///
/// What the editor does itself is the evidence, read out of VS Code's bundled code
/// on 20 Sep 2026 (`out/vs/code/node/cliProcessMain.js`):
///
/// * `.obsolete` — a JSON object whose keys are
///   `` `${id}-${version}${platform ? "-" + platform : ""}` `` and whose values are
///   true. It is written when no profile needs a version any more, and on its next
///   start the editor deletes every folder it names
///   (`deleteExtensionsMarkedForRemoval`). The key carries the manifest's casing
///   and the folder is lowercase, so the match ignores case.
/// * A folder ending `.vsctmp` — a removal that was interrupted
///   (`removeTemporarilyDeletedFolders`).
///
/// So a row here is something the editor has already decided to delete. Cursor,
/// VSCodium, Windsurf and Insiders are built from the same code; their folders are
/// read the same way, which is an inference from their being forks, not something
/// read out of each.
///
/// Not verified against a store in use: this Mac's VS Code had no extensions.
public enum EditorExtensionStores {

    public struct Editor: Sendable, Equatable {
        public let name: String
        /// The folder in the home that holds `extensions/`.
        public let dotFolder: String
        public let bundleIdentifier: String
    }

    public static let editors: [Editor] = [
        Editor(name: "Visual Studio Code", dotFolder: ".vscode",
               bundleIdentifier: "com.microsoft.VSCode"),
        Editor(name: "VS Code Insiders", dotFolder: ".vscode-insiders",
               bundleIdentifier: "com.microsoft.VSCodeInsiders"),
        Editor(name: "VSCodium", dotFolder: ".vscode-oss", bundleIdentifier: "com.vscodium"),
        Editor(name: "Cursor", dotFolder: ".cursor",
               bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", dotFolder: ".windsurf",
               bundleIdentifier: "com.exafunction.windsurf"),
    ]

    /// Home dot-folders this reader speaks for. Hidden & System Data lists large
    /// dot-folders whole, and `~/.vscode` whole is an offer to delete every
    /// extension the user has installed.
    public static var homeDotFolders: Set<String> { Set(editors.map(\.dotFolder)) }

    public struct ObsoleteExtension: Sendable, Equatable {
        public let url: URL
        public let editor: Editor
    }

    public static func obsolete(home: URL) -> [ObsoleteExtension] {
        editors.flatMap { editor -> [ObsoleteExtension] in
            let store = home.appendingPathComponent(editor.dotFolder, isDirectory: true)
                .appendingPathComponent("extensions", isDirectory: true)
            let marked = markedForRemoval(in: store)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
            return names.sorted().compactMap { name in
                guard !name.hasPrefix("."),
                      marked.contains(name.lowercased()) || name.hasSuffix(temporarySuffix)
                else { return nil }
                let url = store.appendingPathComponent(name, isDirectory: true)
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return nil }
                return ObsoleteExtension(url: url, editor: editor)
            }
        }
    }

    static let temporarySuffix = ".vsctmp"

    /// The keys of `.obsolete` whose value is true, lowercased. A file that is not
    /// the JSON object the editor writes names nothing: an unreadable record is not
    /// permission.
    static func markedForRemoval(in store: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: store.appendingPathComponent(".obsolete")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(object.compactMap { key, value in
            (value as? Bool) == true ? key.lowercased() : nil
        })
    }

    /// `vendor.tool-1.2.3-darwin-arm64` → `vendor.tool 1.2.3`, for a row's name.
    public static func displayName(forFolder name: String) -> String {
        var name = name
        if name.hasSuffix(temporarySuffix) { name.removeLast(temporarySuffix.count) }
        guard let match = name.range(of: #"-\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return name
        }
        let version = name[match].dropFirst()
        return "\(name[..<match.lowerBound]) \(version)"
    }
}
