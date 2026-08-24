import Foundation

/// A Vision feature print, reduced to plain floats.
///
/// `VNFeaturePrintObservation` can compare itself with `computeDistance(_:to:)`, but
/// keeping that call in the app layer would put the similarity threshold — the single
/// number that decides whether two photos are "the same" — somewhere `swift test`
/// cannot reach. The observation exposes `data`, `elementCount` and `elementType`, so
/// the app unpacks it into this and Core owns the arithmetic.
public struct PhotoFingerprint: Sendable, Equatable {

    public let vector: [Float]

    public init(vector: [Float]) {
        self.vector = vector
    }

    /// Whether two prints are within `threshold` of each other.
    ///
    /// Preferred over `distance(to:)` for clustering, and not merely as a
    /// convenience. Clustering is O(n²) inside a bucket, and one bulk import in a
    /// real library put 6,003 photographs into a single bucket — 18 million pairs.
    /// Computing a full 768-dimension distance for each was enough to make the app
    /// look frozen.
    ///
    /// Squared distance only ever grows as dimensions are added, so once it passes
    /// the threshold the pair can be rejected without reading the rest of the vector.
    /// The overwhelming majority of pairs are nothing alike and exit within a handful
    /// of dimensions. The result is exact — this prunes work, never matches.
    public func isWithin(_ threshold: Float, of other: PhotoFingerprint) -> Bool {
        guard vector.count == other.vector.count, !vector.isEmpty else { return false }
        let limit = threshold * threshold
        var sum: Float = 0
        for i in vector.indices {
            let delta = vector[i] - other.vector[i]
            sum += delta * delta
            if sum > limit { return false }
        }
        return true
    }

    /// Euclidean distance, matching what Vision's own `computeDistance` returns.
    ///
    /// Vectors of differing length cannot be compared — that means two different
    /// request revisions produced them, and a number derived from the overlap would
    /// be meaningless rather than merely imprecise.
    public func distance(to other: PhotoFingerprint) -> Float? {
        guard vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var sum: Float = 0
        for i in vector.indices {
            let delta = vector[i] - other.vector[i]
            sum += delta * delta
        }
        return sum.squareRoot()
    }
}
