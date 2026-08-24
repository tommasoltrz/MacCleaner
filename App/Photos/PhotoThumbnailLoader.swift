import SwiftUI
import Photos
import AppKit

/// Loads grid thumbnails, once each.
///
/// The review grid is the whole point of the feature — a bulk delete the user cannot
/// see is not reviewable — so this is on the critical path for trust, not just for
/// looks. Requests are cached and de-duplicated because SwiftUI rebuilds rows freely
/// while scrolling, and an uncached loader would re-request the same asset (and, for
/// anything not held locally, re-fetch it from iCloud) on every pass.
@MainActor
@Observable
final class PhotoThumbnailLoader {

    /// Retina-friendly for the grid's ~120pt cells without holding full previews.
    private nonisolated static let edge: CGFloat = 320

    /// Full-size previews are expensive to hold, so only the last few are kept.
    /// Opening a photo, stepping through its group and closing again must not
    /// accumulate a dozen 12-megapixel images in memory.
    private static let previewCacheLimit = 8

    private var images: [String: NSImage] = [:]
    private var previews: [String: NSImage] = [:]
    private var previewOrder: [String] = []
    private var inFlight: Set<String> = []
    private var previewsInFlight: Set<String> = []

    /// 0...1 while an original is coming down from iCloud, nil otherwise.
    private(set) var downloadProgress: [String: Double] = [:]

    /// The cached image, or nil while it loads.
    func image(for assetID: String) -> NSImage? { images[assetID] }

    func load(_ assetID: String) {
        guard images[assetID] == nil, !inFlight.contains(assetID) else { return }
        inFlight.insert(assetID)

        Task { [weak self] in
            let image = await Self.fetch(assetID)
            guard let self else { return }
            self.inFlight.remove(assetID)
            guard let image else { return }
            self.images[assetID] = image
        }
    }

    /// The full-quality image, or nil while it loads.
    ///
    /// Falls back to the grid thumbnail so the sheet shows something the instant it
    /// opens and sharpens when the original lands, rather than presenting an empty
    /// rectangle above a Delete button.
    func preview(for assetID: String) -> NSImage? { previews[assetID] ?? images[assetID] }

    /// True while the shown image is still the low-resolution stand-in.
    func isPreviewLoading(_ assetID: String) -> Bool { previews[assetID] == nil }

    /// Fetches the original at full resolution, downloading it from iCloud if needed.
    ///
    /// The sweep deliberately never does this — it fingerprints thumbnails so it can
    /// compare 12,000 photographs without pulling the library down. Opening one photo
    /// is the opposite case: it is a single deliberate act, and the decision it
    /// supports is whether to delete a photograph, which nobody should make from a
    /// 256-pixel derivative.
    func loadPreview(_ assetID: String) {
        guard previews[assetID] == nil, !previewsInFlight.contains(assetID) else { return }
        previewsInFlight.insert(assetID)

        // Built here rather than inside the Task: nesting a second `[weak self]`
        // inside a closure that has already captured it captures the capture, not
        // the object.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.downloadProgress[assetID] = fraction }
        }

        Task { [weak self] in
            let image = await Self.fetchOriginal(assetID, onProgress: report)
            guard let self else { return }
            self.previewsInFlight.remove(assetID)
            self.downloadProgress[assetID] = nil
            guard let image else { return }

            self.previews[assetID] = image
            self.previewOrder.append(assetID)
            while self.previewOrder.count > Self.previewCacheLimit {
                self.previews.removeValue(forKey: self.previewOrder.removeFirst())
            }
        }
    }

    private nonisolated static func fetchOriginal(
        _ assetID: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        // Guarantees the best available representation and exactly one callback —
        // `.fastFormat` returns whatever is quickest, which under Optimize Mac
        // Storage is the low-resolution local derivative, and `.opportunistic` calls
        // back more than once, which would trap the continuation.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.progressHandler = { fraction, _, _, _ in onProgress(fraction) }

        // Bounded like the fingerprint path: PhotoKit sometimes never calls back,
        // and an unbounded continuation here left the preview hung forever. Long,
        // because a full-quality original may be coming down from iCloud.
        return await TimedImageRequest().image(
            for: asset,
            size: PHImageManagerMaximumSize,
            options: options,
            timeout: 60
        )
    }

    private nonisolated static func fetch(
        _ assetID: String,
        edge: CGFloat = PhotoThumbnailLoader.edge,
        mode: PHImageContentMode = .aspectFill
    ) async -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else { return nil }

        let options = PHImageRequestOptions()
        // The sweep has already paid to bring these renditions down, so by the time
        // the grid renders they are usually local. Network stays allowed for the
        // remainder rather than showing the user an empty tile above a Delete button.
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        // Same guard as the preview path: a grid tile that never resolves is a
        // leaked task per photo. Short, because these are fast-format requests.
        return await TimedImageRequest().image(
            for: asset,
            size: CGSize(width: edge, height: edge),
            contentMode: mode,
            options: options,
            timeout: 20
        )
    }
}
