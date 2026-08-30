import Foundation

/// What the app layer must supply for a duplicate sweep to run.
///
/// PhotoKit and Vision live behind this protocol so `DuplicateGrouper` and
/// `PhotoDuplicateService` stay testable: PhotoKit answers only inside a signed,
/// bundled app holding an authorization grant, which `swift test` is not.
public protocol PhotoLibraryProviding: Sendable {

    /// Current access, requesting it if the user has not been asked yet.
    func authorize() async -> PhotoLibraryAccess

    /// Every asset in the library, hidden ones included — the grouper decides what
    /// to exclude, so that policy lives in one tested place rather than here.
    func fetchAssets() async throws -> [PhotoAsset]

    /// A Vision feature print built from the asset's **thumbnail**.
    ///
    /// Returns nil when no local thumbnail exists. Implementations must not reach
    /// the network: with Optimize Mac Storage the originals live in iCloud, and
    /// fingerprinting by download would pull the library down a photo at a time.
    /// A nil here is reported as skipped, never treated as "no match".
    func fingerprint(assetID: String) async -> PhotoFingerprint?

    /// Moves assets to the library's Recently Deleted.
    ///
    /// This is not a local operation: the deletion syncs to every device on the same
    /// iCloud library, which is the point, and is also why the caller must have
    /// confirmed it. Space is not reclaimed until Recently Deleted is emptied —
    /// PhotoKit exposes no album for that, so only the user can do it.
    func delete(assetIDs: [String]) async throws
}

public enum PhotoLibraryAccess: Sendable, Equatable {
    case authorized
    /// The user granted access to a chosen subset. Duplicate detection over a
    /// partial library would compare a photo against copies it cannot see, so the
    /// feature reports this as unusable rather than producing confident nonsense.
    case limited
    case denied
    case restricted

    public var canSweep: Bool { self == .authorized }

    /// User-facing copy naming the remedy, per the design's rule that an
    /// unavailable feature says how to fix itself.
    public var unavailableReason: String? {
        switch self {
        case .authorized:
            nil
        case .limited:
            "Scolo can only see some of your photos, so it cannot tell which are "
                + "duplicates. Grant full access in System Settings › Privacy & Security › Photos."
        case .denied:
            "Scolo needs access to your photo library. Turn it on in "
                + "System Settings › Privacy & Security › Photos."
        case .restricted:
            "Access to the photo library is restricted on this Mac."
        }
    }
}

/// Why a sweep could not run. Distinct from "ran and found nothing".
public enum PhotoSweepUnavailable: Error, Sendable, Equatable {
    case access(PhotoLibraryAccess)
    /// iCloud Photos is on but the library has not finished coming down. Sweeping
    /// now would compare a photo against copies that have not arrived yet.
    case librarySyncing(assetCount: Int)
}
