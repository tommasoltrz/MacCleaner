import Foundation
import Testing
@testable import ScoloCore

/// The iCloud card reports three numbers, and two of them come from sources that can
/// lie by omission: `brctl` gives free space but never the plan, and the ubiquity
/// container gives iCloud Drive but nothing about Photos or backups. The arithmetic
/// tying them together is the only place that can turn "we don't know" into a
/// confident wrong figure, so it is pinned here.
@Suite("iCloud storage")
struct ICloudStorageTests {

    private let gib: Int64 = 1024 * 1024 * 1024

    // MARK: - brctl

    @Test("Quota output is read from its leading integer")
    func parsesQuota() {
        // The exact line a real account produced.
        #expect(ICloudStorageService.parseQuota(
            "158671798507 bytes of quota remaining in personal account\n") == 158_671_798_507)
        #expect(ICloudStorageService.parseQuota("0 bytes of quota remaining") == 0)
    }

    @Test("Anything that is not a byte count is rejected rather than read as zero")
    func rejectsUnparsableQuota() {
        // Reading a failure as "0 bytes free" would render a full account and prompt
        // the user to delete things they do not need to.
        for text in ["", "  ", "brctl: not signed in", "unknown\n", "-5 bytes"] {
            #expect(ICloudStorageService.parseQuota(text) == nil, "accepted \(text.debugDescription)")
        }
    }

    // MARK: - Plan inference

    @Test("The plan is the smallest tier that could hold the free space")
    func infersPlan() {
        // The real case: 147.77 GiB free resolves to the 200 GiB plan, which is what
        // iCloud's own page reported.
        #expect(ICloudStorageService.inferPlan(freeBytes: 158_671_798_507) == 200 * gib)
        #expect(ICloudStorageService.inferPlan(freeBytes: 1 * gib) == 5 * gib)
        #expect(ICloudStorageService.inferPlan(freeBytes: 60 * gib) == 200 * gib)
        #expect(ICloudStorageService.inferPlan(freeBytes: 300 * gib) == 2048 * gib)
    }

    @Test("A free space beyond every tier clamps to the largest rather than overflowing")
    func planInferenceClamps() {
        #expect(ICloudStorageService.inferPlan(freeBytes: 99_999 * gib) == 12288 * gib)
    }

    // MARK: - The residual

    @Test("Used, and the unmeasured remainder, reconcile with the real account")
    func reconcilesWithRealAccount() {
        // The figures iCloud's own page showed: 200 GB plan, 147.8 free, 52.2 used,
        // 5.7 of it Documents. Ours must land on the same numbers.
        let storage = ICloudStorage(
            totalBytes: 200 * gib,
            freeBytes: 158_671_798_507,
            documentsBytes: 6_080_000_000
        )
        #expect(abs(Double(storage.usedBytes) / Double(gib) - 52.2) < 0.1)
        #expect(abs(Double(storage.documentsBytes) / Double(gib) - 5.7) < 0.1)
        // Photos (33) + Backup (13.5) ≈ 46.5, which is what is left once Drive is out.
        #expect(abs(Double(storage.unmeasuredBytes) / Double(gib) - 46.5) < 0.2)
    }

    @Test("The unmeasured segment never goes negative")
    func unmeasuredIsClamped() {
        // Quota and the Drive walk are separate readings taken moments apart, so the
        // Drive figure can legitimately exceed the used figure. A negative segment
        // would render as a glitch and imply a precision neither number has.
        let storage = ICloudStorage(
            totalBytes: 200 * gib, freeBytes: 199 * gib, documentsBytes: 50 * gib
        )
        #expect(storage.unmeasuredBytes == 0)
    }

    @Test("Empty segments are dropped, and the rest sum to the plan")
    func segmentsAreWellFormed() {
        let storage = ICloudStorage(
            totalBytes: 200 * gib, freeBytes: 150 * gib, documentsBytes: 6 * gib
        )
        #expect(storage.segments.map(\.id) == [.documents, .unmeasured, .free])
        #expect(storage.segments.reduce(0) { $0 + $1.bytes } == 200 * gib)

        // Nothing in Drive at all: that segment disappears rather than rendering a
        // zero-width sliver in the bar.
        let empty = ICloudStorage(totalBytes: 200 * gib, freeBytes: 150 * gib, documentsBytes: 0)
        #expect(empty.segments.map(\.id) == [.unmeasured, .free])
    }

    @Test("Unmeasured says why it cannot be broken down")
    func unmeasuredExplainsItself() {
        // The predecessor mislabelled its residual twice, presenting guesses as
        // measurements. This one names the things it cannot see.
        let explanation = ICloudSegmentID.unmeasured.explanation ?? ""
        #expect(explanation.contains("Photos"))
        #expect(explanation.contains("backups"))
        #expect(ICloudSegmentID.unmeasured.displayName == "Unmeasured")
    }
}
