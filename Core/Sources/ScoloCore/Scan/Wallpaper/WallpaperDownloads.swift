import CryptoKit
import Foundation

/// A download must still match its scan identity and current wallpaper settings.
public struct WallpaperDownload: Sendable, Equatable {
    let root: URL
    let identity: String
    let selectionFingerprint: Data?
    let needsReview: Bool

    func permitsRemoval(of url: URL) -> Bool {
        let home = root.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard WallpaperDownloads.isDirect(root, under: home),
              WallpaperDownloads.isDirectFile(url, under: root), FileIdentity.of(url) == identity,
              let catalog = WallpaperDownloads.catalog(at: root),
              let asset = catalog.asset(for: url) else { return false }
        let selection = WallpaperDownloads.selection(at: root, catalog: catalog)
        guard !selection.selectedIDs.contains(asset.id) else { return false }
        if selection.isComplete { return true }
        return needsReview && selection.fingerprint == selectionFingerprint
    }
}

/// Reads local Apple wallpaper metadata. It never downloads files or changes settings.
enum WallpaperDownloads {
    static let relativeRoot = "Library/Application Support/com.apple.wallpaper/aerials"
    static let reviewReason = "Check Wallpaper settings before removing this download"
    static let selectedReason = "This download is selected for a wallpaper or screen saver. Change the selection in Wallpaper settings first."

    struct Asset: Decodable {
        let id: String
        let accessibilityLabel: String?
        let categories: [String]?
        let subcategories: [String]?
        let downloadURL: String?

        enum CodingKeys: String, CodingKey {
            case id, accessibilityLabel, categories, subcategories
            case downloadURL = "url-4K-SDR-240FPS"
        }

        var canDownload: Bool {
            guard UUID(uuidString: id) != nil, let downloadURL, let url = URL(string: downloadURL),
                  url.scheme == "https", let host = url.host else { return false }
            return host == "apple.com" || host.hasSuffix(".apple.com")
        }
    }

    struct Catalog: Decodable {
        let assets: [Asset]

        func asset(for url: URL) -> Asset? {
            guard url.pathExtension.lowercased() == "mov" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            let matches = assets.filter { $0.id == id && $0.canDownload }
            return matches.count == 1 ? matches.first : nil
        }
    }

    struct Selection {
        var selectedIDs = Set<String>()
        var isComplete = true
        var fingerprint: Data?
    }

    static func catalog(at root: URL) -> Catalog? {
        guard let data = metadata(root.appendingPathComponent("manifest/entries.json"), under: root) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    static func selection(at root: URL, catalog: Catalog) -> Selection {
        let settings = root.deletingLastPathComponent().appendingPathComponent("Store/Index.plist")
        guard let data = metadata(settings, under: root.deletingLastPathComponent()),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let index = plist as? [String: Any],
              index["SystemDefault"] is [String: Any], index["Spaces"] is [String: Any],
              index["Displays"] is [String: Any] else {
            return Selection(isComplete: false)
        }
        let desktops = desktopSelections(at: root, index: index)
        var result = Selection(isComplete: desktops.isComplete,
                               fingerprint: selectionFingerprint(["index": index, "desktops": desktops.fingerprint]))
        if !Set(index.keys).isSubset(of: ["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"]) {
            result.isComplete = false
        }
        var choices = 0

        func inspect(_ value: Any, depth: Int = 0) {
            guard depth < 32 else { result.isComplete = false; return }
            if let array = value as? [Any] {
                for item in array { inspect(item, depth: depth + 1) }
            } else if let dictionary = value as? [String: Any] {
                if let provider = dictionary["Provider"] as? String {
                    choices += 1
                    guard let bytes = dictionary["Configuration"] as? Data,
                          let decoded = try? PropertyListSerialization.propertyList(from: bytes, format: nil),
                          let configuration = decoded as? [String: Any] else {
                        result.isComplete = false
                        return
                    }
                    if provider == "com.apple.wallpaper.choice.aerials" {
                        guard let id = configuration["assetID"] as? String else {
                            result.isComplete = false
                            return
                        }
                        let matching = catalog.assets.filter {
                            $0.id == id || ($0.categories ?? []).contains(id) || ($0.subcategories ?? []).contains(id)
                        }
                        if matching.isEmpty { result.isComplete = false }
                        result.selectedIDs.formUnion(matching.map(\.id))
                        // Dynamic wallpapers can switch between light and dark video variants.
                        for asset in matching where (asset.categories ?? []).contains("dynamic-aerials") {
                            let groups = Set(asset.subcategories ?? [])
                            if groups.isEmpty { result.isComplete = false }
                            result.selectedIDs.formUnion(catalog.assets.filter {
                                !groups.isDisjoint(with: $0.subcategories ?? [])
                            }.map(\.id))
                        }
                    } else if provider == "com.apple.wallpaper.choice.image",
                              configuration["type"] as? String == "imageFile",
                              let location = configuration["url"] as? [String: Any],
                              let relative = location["relative"] as? String,
                              let url = URL(string: relative), url.isFileURL {
                        if let asset = catalog.asset(for: url) { result.selectedIDs.insert(asset.id) }
                    } else {
                        // An unknown provider or default screen saver cannot establish an unused download.
                        result.isComplete = false
                    }
                    return
                }
                for key in ["Desktop", "Idle", "Linked"] where dictionary[key] != nil {
                    if let slot = dictionary[key] as? [String: Any], slot["Content"] is [String: Any] { continue }
                    result.isComplete = false
                }
                if let content = dictionary["Content"] as? [String: Any] {
                    guard let items = content["Choices"] as? [[String: Any]], !items.isEmpty,
                          items.allSatisfy({ $0["Provider"] is String }) else {
                        result.isComplete = false
                        return
                    }
                    if let shuffle = content["Shuffle"], !(shuffle is String && shuffle as? String == "$null") {
                        result.isComplete = false
                    }
                }
                for item in dictionary.values { inspect(item, depth: depth + 1) }
            }
        }
        for configuration in desktops.configurations { inspect(configuration) }
        if choices == 0 { result.isComplete = false }
        return result
    }

    private static func selectionFingerprint(_ index: [String: Any]) -> Data? {
        func normalized(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "LastSet" && $0.key != "LastUse" }
                    .mapValues(normalized)
            }
            if let array = value as? [Any] { return array.map(normalized) }
            if let data = value as? Data { return ["data": data.base64EncodedString()] }
            if let date = value as? Date { return ["date": date.timeIntervalSinceReferenceDate] }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized(index), options: [.sortedKeys]) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    static func classify(_ original: FileEntry, root: URL, catalog knownCatalog: Catalog? = nil,
                         selection knownSelection: Selection? = nil) -> FileEntry {
        var entry = original
        let home = root.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard isDirect(root, under: home), isDirectFile(entry.url, under: root),
              let identity = FileIdentity.of(entry.url),
              let catalog = knownCatalog ?? catalog(at: root), let asset = catalog.asset(for: entry.url) else {
            entry.isRegenerable = false
            entry.inventoryReason = "Scolo cannot verify this wallpaper download. Review it in Wallpaper settings."
            return entry
        }
        let selection = knownSelection ?? selection(at: root, catalog: catalog)
        entry.displayName = "Wallpaper · " + (asset.accessibilityLabel ?? asset.id)
        if selection.selectedIDs.contains(asset.id) {
            entry.inventoryReason = selectedReason
            entry.contentDescription = "Selected for a wallpaper or screen saver"
        } else if !selection.isComplete {
            entry.safeRemovalReviewReason = reviewReason
            entry.contentDescription = "Downloaded video. Check Wallpaper settings before removal."
        }
        entry.wallpaperDownload = WallpaperDownload(
            root: root, identity: identity, selectionFingerprint: selection.fingerprint,
            needsReview: !selection.isComplete
        )
        return entry
    }

    static func isDirectFile(_ url: URL, under root: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("videos").standardizedFileURL
            && isDirect(url, under: root)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    static func isDirect(_ url: URL, under root: URL) -> Bool {
        !AppUninstallPlanner.isSymbolicLink(url)
            && !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: root)
            && !AppUninstallPlanner.isSymbolicLink(root)
    }

    static func metadata(_ url: URL, under root: URL) -> Data? {
        guard isDirect(url, under: root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
}
