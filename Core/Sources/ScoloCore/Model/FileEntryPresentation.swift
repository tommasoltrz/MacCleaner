import Foundation

/// Describes an item without changing its removal rules.
public struct FileEntryPresentation: Sendable, Equatable {
    public enum Icon: Sendable, Equatable {
        case node, react, code, photo, video, music, cache, log
        case archive, diskImage, folder, document, application, package, backup
    }

    public let summary: String
    public let icon: Icon

    public init(entry: FileEntry, project: Project? = nil) {
        let name = entry.url.lastPathComponent.lowercased()
        let ext = entry.url.pathExtension.lowercased()
        let parentURL = entry.url.deletingLastPathComponent()
        let parent = parentURL.lastPathComponent
        let context = ["ios", "android"].contains(parent)
            ? parentURL.deletingLastPathComponent().lastPathComponent + " / " + parent : parent
        let location = context.isEmpty ? "" : " · \(context)"
        let type: String
        let symbol: Icon

        if entry.inventoryReason != nil {
            type = "Protected data"
            symbol = .folder
        } else if entry.removalAction != nil {
            type = "Files left by a removed app"
            symbol = .application
        } else if entry.kind == .appBundle || entry.kind == .downloadedApp {
            type = entry.kind == .appBundle ? "Installed application" : "Downloaded application"
            symbol = .application
        } else if name == "node_modules" {
            type = "Node.js dependencies"
            symbol = .node
        } else if name == "pods", entry.kind == .cache {
            type = "iOS project dependencies"
            symbol = .package
        } else if [".venv", "venv"].contains(name), entry.kind == .cache {
            type = "Python project environment"
            symbol = .code
        } else if ["__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache"].contains(name) {
            type = "Python tool cache"
            symbol = .code
        } else if name == ".gradle" {
            type = "Gradle build cache"
            symbol = .code
        } else if ["lrdata", "lrprev"].contains(ext) {
            type = "Lightroom photo previews"
            symbol = .photo
        } else if ["photoslibrary", "photolibrary"].contains(ext) {
            type = "Photo library"
            symbol = .photo
        } else if ["imovielibrary", "fcpbundle"].contains(ext) {
            type = "Video project library"
            symbol = .video
        } else if let project {
            type = project.rawValue
            symbol = project == .react || project == .reactNative ? .react : .node
        } else if entry.kind == .archive {
            type = "Compressed archive"
            symbol = .archive
        } else if entry.kind == .diskImage {
            type = "Disk image"
            symbol = .diskImage
        } else if entry.kind == .file {
            switch ext {
            case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "raw", "dng", "svg":
                type = "Image file"; symbol = .photo
            case "mov", "mp4", "m4v", "mkv", "avi", "webm":
                type = "Video file"; symbol = .video
            case "mp3", "m4a", "wav", "aiff", "flac", "aac":
                type = "Audio file"; symbol = .music
            case "log":
                type = "Activity log"; symbol = .log
            case "pdf":
                type = "PDF document"; symbol = .document
            case "pkg":
                type = "Installer package"; symbol = .package
            case "swift", "js", "jsx", "ts", "tsx", "py", "rs", "go", "html", "css":
                type = "Source code"; symbol = .code
            default:
                type = "File"; symbol = .document
            }
        } else if entry.kind == .cache {
            type = "Cached files"
            symbol = .cache
        } else if entry.url.pathComponents.contains("Logs") {
            type = "Activity logs"
            symbol = .log
        } else if entry.url.pathComponents.contains("MobileSync") && parent == "Backup" {
            type = "iPhone or iPad backup"
            symbol = .backup
        } else {
            type = "Folder"
            symbol = .folder
        }

        var detail = entry.contentDescription ?? (type + location)
        if let caveat = entry.safetyCaveat { detail += " · \(caveat)" }
        if let reason = entry.safeRemovalReviewReason { detail += " · \(reason)" }
        if entry.contentDescription == nil, type == "Folder", let count = entry.childCount {
            detail += " · \(count.formatted()) \(count == 1 ? "item" : "items")"
        }
        summary = detail
        icon = symbol
    }

    public enum Project: String, Sendable {
        case node = "Node.js project"
        case react = "React project"
        case reactNative = "React Native project"
    }

    /// Reads one small manifest. Call this outside the main thread.
    public static func project(at directory: URL) -> Project? {
        let url = directory.appendingPathComponent("package.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 128 * 1024,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1024 + 1), data.count <= 128 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let groups = ["dependencies", "devDependencies", "peerDependencies"]
        let packages = groups.compactMap { object[$0] as? [String: Any] }
        if packages.contains(where: { $0["react-native"] as? String != nil }) { return .reactNative }
        if packages.contains(where: { $0["react"] as? String != nil }) { return .react }
        guard object["name"] is String || !packages.isEmpty || object["scripts"] is [String: Any]
        else { return nil }
        return .node
    }
}
