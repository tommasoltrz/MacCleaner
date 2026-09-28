import Foundation

extension StorageRuleRegistry {
    static let wallpaperDownloadRule = StorageRule(
        id: "wallpaper:download", path: WallpaperDownloads.relativeRoot + "/videos/*.mov",
        owner: "macOS Wallpapers", ownerRules: [], category: .systemCaches, dataType: .cache,
        summary: "Downloaded wallpaper video. macOS can download it again when selected.",
        removalEffect: "Removes the downloaded video. A future download needs an internet connection.",
        evidence: .init(basis: .localInspection,
                        reference: "Local Apple aerials manifest and Store/Index.plist inspected on macOS 27. Files use manifest asset identifiers.")
    )

    static let wallpaperRules: [StorageRule] = [
        StorageRule(
            id: "wallpaper:store", path: "Library/Application Support/com.apple.wallpaper",
            owner: "macOS Wallpapers", ownerRules: [], category: .systemCaches, dataType: .managedLibrary,
            title: "Downloaded Wallpapers", summary: "Select individual downloads to keep wallpaper settings and selected videos.",
            removalEffect: "This folder contains wallpaper settings and selected downloads. Select individual downloads instead.",
            evidence: wallpaperDownloadRule.evidence
        ),
        wallpaperDownloadRule
    ]
}
