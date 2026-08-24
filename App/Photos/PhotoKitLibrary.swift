import Foundation
import Photos
import Vision
import AppKit
import MacCleanerCore

/// `PhotoLibraryProviding` backed by the real photo library.
///
/// Everything PhotoKit- and Vision-shaped is confined here so Core keeps its
/// no-framework, fully testable grouping logic. The type holds no mutable state —
/// every call goes straight to PhotoKit, which is itself thread-safe — so the
/// unchecked conformance costs nothing to reason about.
final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {

    /// Thumbnails are requested at this edge length.
    ///
    /// Feature prints are computed from thumbnails deliberately: with Optimize Mac
    /// Storage the originals live in iCloud, and fingerprinting from originals would
    /// pull the entire library down one photo at a time. 256px is comfortably above
    /// what Vision needs to separate distinct scenes.
    private static let thumbnailEdge: CGFloat = 256

    /// Whether a missing thumbnail may be fetched from iCloud.
    ///
    /// With Optimize Mac Storage the derivatives are not on disk — this library had
    /// 148 of them for 12,963 assets — so with this off the sweep skips essentially
    /// everything and finds nothing. On, each miss costs one small rendition, not the
    /// full-resolution original: the request asks for a 256px image, and PhotoKit
    /// fetches a correspondingly small derivative.
    let allowsNetworkFetch: Bool

    init(allowsNetworkFetch: Bool = true) {
        self.allowsNetworkFetch = allowsNetworkFetch
    }

    /// Pinned rather than left at `.current`: a feature print is only comparable to
    /// another from the same revision, and letting an OS update move this would
    /// silently invalidate every cached print.
    static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2

    // MARK: - Access

    func authorize() async -> PhotoLibraryAccess {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = current
        }

        return switch status {
        case .authorized: .authorized
        case .limited:    .limited
        case .restricted: .restricted
        default:          .denied
        }
    }

    // MARK: - Fetch

    func fetchAssets() async throws -> [PhotoAsset] {
        // `PHAsset` is not Sendable, so it never leaves this scope — the mapping to
        // Core's value type happens inline and only `[PhotoAsset]` crosses out.
        let options = PHFetchOptions()
        // Hidden assets are fetched so the grouper can apply its own exclusion rule
        // in one tested place, rather than that policy being split across layers.
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            assets.append(Self.map(asset))
        }
        return assets
    }

    private static func map(_ asset: PHAsset) -> PhotoAsset {
        let mediaType: PhotoAsset.MediaType = switch asset.mediaType {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default:     .unknown
        }

        return PhotoAsset(
            id: asset.localIdentifier,
            // `PHAssetResource` is the only public route to a filename, and building
            // one per asset across a 13,000-item library is far too slow for a value
            // used only as a label. Left nil; the grid shows the date instead.
            filename: nil,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mediaType: mediaType,
            duration: asset.duration,
            burstIdentifier: asset.burstIdentifier,
            representsBurst: asset.representsBurst,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            hasAdjustments: asset.hasAdjustments
        )
    }

    // MARK: - Fingerprints

    func fingerprint(assetID: String) async -> PhotoFingerprint? {
        guard let image = await thumbnail(for: assetID) else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return await Self.featurePrint(from: cgImage)
    }

    /// Runs the Vision request off the cooperative pool. See `visionQueue`.
    private static func featurePrint(from cgImage: CGImage) async -> PhotoFingerprint? {
        let image = cgImage
        return await withCheckedContinuation { continuation in
            visionQueue.async {
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = featurePrintRevision

                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                guard let observation = request.results?.first as? VNFeaturePrintObservation,
                      observation.elementType == .float
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let floats = observation.data.withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Float.self).prefix(observation.elementCount))
                }
                continuation.resume(returning: floats.isEmpty ? nil : PhotoFingerprint(vector: floats))
            }
        }
    }

    /// Vision work runs here, never on the Swift concurrency pool.
    ///
    /// `VNImageRequestHandler.perform` is synchronous: it blocks its calling thread
    /// inside `VNControlledCapacityTasksQueue.dispatchGroupWait` until Vision's own
    /// workers finish. Called straight from an async function it occupies a
    /// cooperative-pool thread, and the pool only has one per core — so eight
    /// concurrent fingerprints consumed every thread, leaving none for the work
    /// Vision was itself waiting on. The sweep deadlocked at 0% CPU with zero
    /// photos processed.
    ///
    /// Handing the blocking call to a dedicated queue keeps the cooperative pool
    /// free to make progress, which is the rule this violated: never block in async
    /// code.
    private static let visionQueue = DispatchQueue(
        label: "com.tommasolaterza.MacCleaner.vision",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// How long a single thumbnail request may take before it is abandoned.
    ///
    /// Not a guess at a slow network — a guard against a request that never returns
    /// at all. `PHImageManager.requestImage` invokes its handler exactly once when it
    /// can service a request, and simply never invokes it when it cannot: no error,
    /// no nil. Observed live, `cloudphotod` exited part-way through a sweep and eight
    /// requests hung permanently, which was enough to wedge every worker and freeze
    /// the whole feature with the app sitting at 0% CPU.
    private static let requestTimeout: TimeInterval = 20

    /// The asset's thumbnail, fetched from iCloud when absent and permitted.
    ///
    /// Returns nil on timeout, which the sweep counts as skipped — an honest "not
    /// compared" rather than a stall.
    private func thumbnail(for assetID: String) async -> NSImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkFetch
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await TimedImageRequest().image(
            for: asset,
            size: CGSize(width: Self.thumbnailEdge, height: Self.thumbnailEdge),
            options: options,
            timeout: Self.requestTimeout
        )
    }

    // MARK: - Deletion

    func delete(assetIDs: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}


/// One `PHImageManager` request, bounded by a timeout.
///
/// Exists because the continuation must be resumed exactly once no matter which of
/// two racing events happens first — PhotoKit's handler, or the deadline. Resuming a
/// `CheckedContinuation` twice traps, and never resuming it leaks the task forever;
/// both were reachable without this. The lock makes the winner unambiguous.
final class TimedImageRequest: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var requestID: PHImageRequestID?
    private var timeout: DispatchWorkItem?
    private var finished = false

    func image(
        for asset: PHAsset,
        size: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        options: PHImageRequestOptions,
        timeout: TimeInterval
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let id = PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: contentMode, options: options
            ) { image, _ in
                // Strong, deliberately. Nothing else holds this object once the
                // synchronous part of `withCheckedContinuation` returns, so a weak
                // capture let it deallocate before the callback — and a continuation
                // whose owner is gone is never resumed, hanging the task forever.
                // The retain cycle it creates is broken in `finish`/`expire`.
                self.finish(with: image)
            }

            lock.lock()
            // The handler can fire before `requestImage` has even returned, in which
            // case the request is already over and this id must not be recorded — it
            // would only be handed to `cancelImageRequest` for a request that no
            // longer exists.
            if !finished { requestID = id }
            lock.unlock()

            let deadline = DispatchWorkItem { self.expire() }
            lock.lock()
            if finished { deadline.cancel() } else { self.timeout = deadline }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }

    private func finish(with image: NSImage?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation
        let deadline = timeout
        continuation = nil
        timeout = nil
        lock.unlock()
        // Releases the strong reference the pending block holds, so the object goes
        // away now rather than at the deadline.
        deadline?.cancel()
        waiting?.resume(returning: image)
    }

    private func expire() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation
        let id = requestID
        continuation = nil
        timeout = nil
        lock.unlock()

        // Tell PhotoKit to stop, so an abandoned request is not left occupying its
        // queue for the rest of the sweep.
        if let id { PHImageManager.default().cancelImageRequest(id) }
        waiting?.resume(returning: nil)
    }
}
