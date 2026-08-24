import Foundation
import Testing
@testable import MacCleanerCore

/// The fingerprint cache is hand-rolled binary, so its failure modes are the ones
/// hand-rolled binary always has: a truncated file, a stale format, prints from a
/// Vision revision that is no longer comparable. Every one of those must read as
/// "fingerprint again", never as usable data — a cache that returns a half-decoded
/// vector would silently corrupt every distance comparison built on it.
@Suite("Fingerprint cache")
struct FingerprintCacheTests {

    private func cache(_ prints: [String: [Float]], revision: UInt32 = 2) -> FingerprintCache {
        FingerprintCache(
            visionRevision: revision,
            elementCount: UInt32(prints.values.first?.count ?? 0),
            prints: prints.mapValues { PhotoFingerprint(vector: $0) }
        )
    }

    @Test("A cache survives a round trip intact")
    func roundTrip() {
        let original = cache(["a": [1, 2, 3], "b": [-4, 0.5, 9]])
        let decoded = FingerprintCache.decode(original.encoded(), expectingRevision: 2)

        #expect(decoded?.prints.count == 2)
        #expect(decoded?["a"]?.vector == [1, 2, 3])
        #expect(decoded?["b"]?.vector == [-4, 0.5, 9])
    }

    @Test("Prints from another Vision revision are discarded, not reused")
    func revisionMismatchDiscards() {
        // Two revisions produce vectors in different spaces. Reusing them across a
        // revision bump would compare coordinates that mean different things.
        let data = cache(["a": [1, 2, 3]], revision: 2).encoded()
        #expect(FingerprintCache.decode(data, expectingRevision: 3) == nil)
        #expect(FingerprintCache.decode(data, expectingRevision: 2) != nil)
    }

    @Test("A truncated file decodes to nothing rather than to partial vectors")
    func truncationIsRejected() {
        let data = cache(["a": [1, 2, 3], "b": [4, 5, 6]]).encoded()
        for cut in [data.count - 1, data.count / 2, 8, 2] {
            #expect(FingerprintCache.decode(data.prefix(cut), expectingRevision: 2) == nil,
                    "a file truncated to \(cut) bytes was accepted")
        }
    }

    @Test("Foreign data is rejected on the magic number")
    func foreignDataRejected() {
        #expect(FingerprintCache.decode(Data("not a cache at all".utf8), expectingRevision: 2) == nil)
        #expect(FingerprintCache.decode(Data(), expectingRevision: 2) == nil)
    }

    @Test("Encoding is stable for a given set of prints")
    func encodingIsStable() {
        // Dictionary order is not, so the writer sorts. Without that the file's bytes
        // change on every save and any future content check would thrash.
        #expect(cache(["b": [1], "a": [2]]).encoded() == cache(["a": [2], "b": [1]]).encoded())
    }

    @Test("Prints for assets no longer in the library are dropped")
    func retainingPrunes() {
        var c = cache(["keep": [1], "gone": [2]])
        c.retaining(["keep"])
        #expect(c.prints.keys.sorted() == ["keep"])
    }
}
