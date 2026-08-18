import Testing
@testable import MacCleanerCore

/// Every expected string here is lifted verbatim from the design handoff, so a
/// regression in formatting shows up as a failed spec rather than a visual nit.
@Suite("Byte formatting matches the design handoff")
struct ByteFormattingTests {

    @Test("zero renders as 0 B, not 0.0 MB")
    func zero() {
        #expect(ByteFormatting.string(0) == "0 B")
    }

    @Test("values at or above 1 GB use two decimals and base 1024")
    func gigabytes() {
        #expect(ByteFormatting.string(ByteFormatting.bytesPerGB) == "1.00 GB")
        // 8.42 GB — the Xcode_16.2.xip row in the Scanner table
        #expect(ByteFormatting.string(Int64(8.42 * Double(ByteFormatting.bytesPerGB))) == "8.42 GB")
        // 66.27 GB — the Dashboard "Available" hero number
        #expect(ByteFormatting.string(Int64(66.27 * Double(ByteFormatting.bytesPerGB))) == "66.27 GB")
    }

    @Test("values below 1 GB use one decimal in MB")
    func megabytes() {
        // 492.8 MB — the Package Manager Caches category total
        #expect(ByteFormatting.string(Int64(492.8 * Double(ByteFormatting.bytesPerMB))) == "492.8 MB")
        // 512.0 MB — the Zoom.pkg trash row; the trailing .0 must be kept
        #expect(ByteFormatting.string(512 * ByteFormatting.bytesPerMB) == "512.0 MB")
    }

    @Test("one byte below the GB threshold still renders as MB")
    func boundary() {
        #expect(ByteFormatting.string(ByteFormatting.bytesPerGB - 1) == "1024.0 MB")
    }
}
