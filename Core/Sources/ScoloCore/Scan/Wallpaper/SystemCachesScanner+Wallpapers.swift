import Foundation

extension SystemCachesScanner {
    func appendWallpaperDownloads(
        context: ScanContext, to entries: inout [FileEntry], unreadableCount: inout Int
    ) async throws {
        guard let applicationSupportRoot else { return }
        let root = applicationSupportRoot.appendingPathComponent("com.apple.wallpaper/aerials")
        let videos = root.appendingPathComponent("videos")
        guard FileManager.default.fileExists(atPath: videos.path), !context.isWithinExclusion(videos),
              WallpaperDownloads.isDirect(videos, under: applicationSupportRoot) else { return }
        guard (try? FileManager.default.contentsOfDirectory(atPath: videos.path)) != nil else {
            unreadableCount += 1
            return
        }
        let catalog = WallpaperDownloads.catalog(at: root)
        let selection = catalog.map { WallpaperDownloads.selection(at: root, catalog: $0) }
        let measured = try await context.measurer.measureChildren(of: videos)
        var children: [FileEntry] = []
        for (url, size) in measured {
            try Task.checkCancellation()
            unreadableCount += size.unreadableCount
            guard size.allocatedBytes > 0, !context.isExcluded(url), !size.containsProtectedPattern,
                  WallpaperDownloads.isDirectFile(url, under: root), url.pathExtension.lowercased() == "mov" else { continue }
            let entry = StorageRuleRegistry.wallpaperDownloadRule.apply(to: FileEntry(
                url: url, kind: .file, allocatedBytes: size.allocatedBytes,
                safeRemovalReviewReason: size.unreadableCount > 0 ? "Some download data could not be read" : nil
            ), context: context)
            children.append(WallpaperDownloads.classify(entry, root: root, catalog: catalog, selection: selection))
        }
        guard !children.isEmpty else { return }
        children.sort { $0.allocatedBytes == $1.allocatedBytes ? $0.id < $1.id : $0.allocatedBytes > $1.allocatedBytes }
        var group = FileEntry(
            url: videos, displayName: "Downloaded Wallpapers",
            contentDescription: "Downloaded videos for wallpapers and screen savers. Select individual downloads below.",
            kind: .folder, allocatedBytes: 0,
            inventoryReason: "Select individual downloads. Scolo keeps wallpaper settings and selected videos.",
            childCount: children.count, children: children
        )
        group.storageRule = StorageRuleRegistry.wallpaperRules[0]
        entries.append(group)
    }
}
