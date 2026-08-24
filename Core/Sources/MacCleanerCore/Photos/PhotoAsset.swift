import Foundation

/// One item in the photo library, flattened out of `PHAsset`.
///
/// Core deliberately does not import Photos: PhotoKit only answers inside a bundled
/// app that carries `NSPhotoLibraryUsageDescription` and has been granted access, so
/// linking it here would make the grouping logic untestable by `swift test`. The app
/// layer reads `PHAsset` and hands these across instead.
///
/// Note what is *not* on this type: a byte size. `PHAssetResource` exposes no public
/// size property — only type, filename, content type and pixel dimensions — so the
/// only way to learn an asset's weight is to stream its data, which downloads the
/// original from iCloud. Sizes are therefore never claimed anywhere in this feature;
/// duplicates are reported as counts.
public struct PhotoAsset: Sendable, Equatable, Identifiable {

    public enum MediaType: String, Sendable, Equatable {
        case image, video, audio, unknown
    }

    /// `PHAsset.localIdentifier` — stable, and what deletion is addressed to.
    public let id: String
    public let filename: String?
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mediaType: MediaType
    /// Zero for stills. Part of the exact-match signature so two videos of the same
    /// frame size shot at the same second are not merged on dimensions alone.
    public let duration: TimeInterval
    /// Non-nil when the asset belongs to a burst. Apple's own grouping key, and far
    /// more trustworthy than anything we could infer.
    public let burstIdentifier: String?
    /// The frame Photos picked as the burst's representative.
    public let representsBurst: Bool
    public let isFavorite: Bool
    public let isHidden: Bool
    /// True when the user has edited the asset. An edited copy is the one they
    /// invested in, so it outranks its untouched twin when choosing what to keep.
    public let hasAdjustments: Bool

    public init(
        id: String,
        filename: String? = nil,
        creationDate: Date? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        mediaType: MediaType = .image,
        duration: TimeInterval = 0,
        burstIdentifier: String? = nil,
        representsBurst: Bool = false,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        hasAdjustments: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mediaType = mediaType
        self.duration = duration
        self.burstIdentifier = burstIdentifier
        self.representsBurst = representsBurst
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.hasAdjustments = hasAdjustments
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }

    /// Identity for the *exact* tier: same moment, same shape, same kind.
    ///
    /// Capture time is rounded to the second because the same photo imported twice
    /// can carry sub-second jitter, while two genuinely different shots essentially
    /// never share a whole second *and* identical dimensions.
    ///
    /// `nil` when there is no creation date — an asset with no timestamp has nothing
    /// to match on, and guessing would merge unrelated photos.
    public var exactSignature: String? {
        guard let creationDate else { return nil }
        let second = Int(creationDate.timeIntervalSince1970.rounded())
        return "\(second)|\(pixelWidth)x\(pixelHeight)|\(mediaType.rawValue)|\(Int(duration.rounded()))"
    }
}
