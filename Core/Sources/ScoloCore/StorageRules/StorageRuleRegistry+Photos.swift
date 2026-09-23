import Foundation

extension StorageRuleRegistry {
    /// Apple does not support direct removal of files inside a Photos library.
    static let photosLibraryResourceRules: [StorageRule] = [
        ("derivatives", "Photos · Thumbnails", "Thumbnail files managed by Photos"),
        ("renders", "Photos · Rendered images", "Rendered image files managed by Photos")
    ].map { folder, title, summary in
        StorageRule(
            id: "photos-library:" + folder,
            path: "Pictures/Photos Library.photoslibrary/resources/" + folder,
            owner: "Photos", ownerRules: [.bundleIdentifier("com.apple.Photos")],
            category: .hiddenSystemData, dataType: .managedLibrary,
            title: title, summary: summary,
            removalEffect: "Photos manages these library files. Direct removal can damage the library. Manage photos in Photos instead.",
            evidence: .init(
                basis: .documented,
                reference: "Apple warns against changing library contents. https://support.apple.com/guide/photos/pht12e7a8015/mac"
            )
        )
    }
}
