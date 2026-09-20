import Foundation

/// Names of caches and containers that hold account, identity or payment state, and
/// are never offered.
///
/// `~/Library/Caches` is where "everything regenerates", and for this family that is
/// true and the wrong question. What `accountsd`, `akd` or `identityservicesd`
/// regenerates is an *authorization*, and it gets one by going back to the login
/// keychain for every service it fronts: the storm of "… wants to use the login
/// keychain" password prompts. It is the 19 Sep 2026 fault again — a cache that is
/// regenerable on disk under a process that holds its meaning in memory — with one
/// difference that makes it worse: these are daemons, always running and never in
/// `NSWorkspace.runningApplications`, so `FileEntry.inUseBy` cannot speak for them.
///
/// Nine of these folders were in this Mac's `~/Library/Caches` on 20 Sep 2026, each
/// offered as safe and ticked for the user. They came to a few megabytes between
/// them. Refusing them costs nothing; offering them costs an afternoon of prompts.
///
/// **Provenance, stated plainly.** The prompts were not reproduced here. The list is
/// Purge's (`DeletionSafetyPolicy`, github.com/jithin-sabu/purge-app), whose comments
/// say each name was "caught deleting these in the wild". It is taken on that
/// testimony because the two ways of being wrong are so unequal.
///
/// Two rules, for the reason Purge gives: an exact list has to be extended once per
/// newly met daemon, and every gap is a prompt storm. The fragment rule closes the
/// class, so a name not yet seen is refused for what it says it is. Over-matching is
/// the safe direction — the folder is simply not listed.
public enum IdentityState {

    /// Folders under `~/Library/Caches`, matched exactly, ignoring case.
    static let cacheFolderNames: Set<String> = Set([
        "com.apple.accountsd", "com.apple.appleaccountd", "com.apple.amsaccountsd",
        "com.apple.akd",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.identityservicesd", "com.apple.iCloudHelper", "com.apple.icloudwebd",
        "com.apple.itunescloudd", "com.apple.iCloudNotificationAgent", "PassKit",
        // Not identity: macOS refuses to remove these two even with Full Disk Access,
        // so offering them is offering a failure.
        "CloudKit", "FamilyCircle"
    ].map { $0.lowercased() })

    /// Substrings that mark a name as this family's. Specific on purpose: `authkit`
    /// and `authentication`, not a bare `auth`, which is also "Author".
    static let nameFragments = [
        "account", "icloud", "itunescloud", "appleid", "authkit", "authentication",
        "authorization", "identityservice", "keychain", "passkit"
    ]

    /// Sandbox containers, by bundle-identifier prefix: Passwords, AuthKit, Apple
    /// Account, Internet Accounts and Wallet. The last three entries are containers
    /// macOS itself guards.
    static let containerPrefixes = [
        "com.apple.Passwords", "com.apple.AuthKit", "com.apple.AppleAccount",
        "com.apple.Accounts", "com.apple.PassKit", "com.apple.Internet-Accounts",
        "com.apple.Safari", "com.apple.Home", "com.apple.homed"
    ]

    public static func isIdentityCache(named name: String) -> Bool {
        let lowered = name.lowercased()
        return cacheFolderNames.contains(lowered) || nameFragments.contains { lowered.contains($0) }
    }

    public static func isProtectedContainer(bundleIdentifier: String) -> Bool {
        let lowered = bundleIdentifier.lowercased()
        return containerPrefixes.contains { lowered.hasPrefix($0.lowercased()) }
            || nameFragments.contains { lowered.contains($0) }
    }
}
