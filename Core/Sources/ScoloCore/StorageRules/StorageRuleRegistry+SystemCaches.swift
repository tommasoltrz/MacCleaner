import Foundation

extension StorageRuleRegistry {
    /// A cache an application keeps under `~/Library/Application Support`, where no
    /// cache sweep looks.
    struct ApplicationSupportCache: Sendable {
        let label: String
        let components: [String]
        /// Any running application whose identifier begins with this holds the row.
        let ownerIdentifierPrefix: String
        let evidence: StorageRule.Evidence
    }

    /// A short, audited list — `~/Library/Application Support` is where
    /// applications keep the user's data, and a rule that went looking for
    /// cache-shaped names in it is how a cleaner deletes a project.
    ///
    /// **Adobe's media cache.** Premiere Pro, After Effects and Media Encoder write
    /// conformed audio, peak files and rendered previews to `Common/Media Cache
    /// Files`, and the index that tracks them to `Common/Media Cache`; on a machine
    /// that edits video the pair runs to tens of gigabytes. Adobe's own instruction
    /// for reclaiming the space is to quit its applications and delete both; the
    /// media is conformed again when a project is next opened, which takes minutes.
    /// Only these default locations: a cache the user has pointed at another disk is
    /// theirs to find. `Common` also holds plug-ins and presets, which are not
    /// named and are not touched. An Adobe identifier carries the year
    /// (`com.adobe.PremierePro.24`), so any open Adobe application holds the rows.
    ///
    /// Not seen on this Mac, which has no Adobe application; the paths are Adobe's
    /// published ones, and Purge (github.com/jithin-sabu/purge-app) lists the same
    /// two.
    static let applicationSupportCaches: [ApplicationSupportCache] = [
        ApplicationSupportCache(
            label: "Adobe media cache files",
            components: ["Adobe", "Common", "Media Cache Files"],
            ownerIdentifierPrefix: "com.adobe.", evidence: inheritedEvidence
        ),
        ApplicationSupportCache(
            label: "Adobe media cache database",
            components: ["Adobe", "Common", "Media Cache"],
            ownerIdentifierPrefix: "com.adobe.", evidence: inheritedEvidence
        )
    ]

}

extension StorageRuleRegistry {
    static func systemApplicationCacheRule(identifier: String, name: String, cacheName: String) -> StorageRule {
        let isBooksCover = identifier == "com.apple.iBooksX" && cacheName == "BCCoverCache-1"
        return StorageRule(
            id: "system-app:\(identifier):\(cacheName)",
            path: "Library/Containers/\(identifier)/\(containerCachePath)/\(cacheName)",
            owner: name, ownerRules: [.bundleIdentifier(identifier)], category: .systemCaches, dataType: .cache,
            title: isBooksCover ? "Books · Cover images" : "\(name) · \(cacheName)",
            summary: isBooksCover ? "Cached book cover images" : "Temporary app files that can be recreated or downloaded again",
            removalEffect: "The application recreates or downloads its cache when needed.", evidence: sandboxEvidence
        )
    }

    static func genericCacheRule(name: String, root: String, regenerable: Bool) -> StorageRule {
        StorageRule(
            id: "cache:\(root)/\(name)", path: root + "/" + name,
            owner: name, ownerRules: [.cacheName(name)], category: .systemCaches,
            dataType: regenerable ? .cache : .unknown,
            removalEffect: regenerable ? "The owner recreates these files when needed." : "Removal effects are unknown. Review the contents first.",
            evidence: root == ".cache"
                ? .init(basis: regenerable ? .documented : .unverified,
                        reference: regenerable ? "CACHEDIR.TAG signature verified during scanning. https://bford.info/cachedir/" : "No cache marker found")
                : sandboxEvidence
        )
    }
}
