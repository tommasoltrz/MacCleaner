import Testing

@Suite("Binary formatting for iCloud")
struct BinaryByteFormattingTests {
    @Test("a 200 GiB plan reads as 200 GB, the way iCloud labels it")
    func planTierRoundTrips() {
        let gib: Int64 = 1024 * 1024 * 1024
        #expect(ByteFormatting.binaryString(200 * gib) == "200.00 GB")
        #expect(ByteFormatting.string(200 * gib) == "214.75 GB", "the decimal formatter is the wrong tool here")
        #expect(ByteFormatting.binaryString(5 * 1024 * 1024) == "5.0 MB")
        #expect(ByteFormatting.binaryString(0) == "0 B")
    }
}
@testable import MacCleanerCore

/// Storage figures use the same decimal units as macOS.
@Suite("Byte formatting matches macOS storage units")
struct ByteFormattingTests {

    @Test("zero renders as 0 B, not 0.0 MB")
    func zero() {
        #expect(ByteFormatting.string(0) == "0 B")
    }

    @Test("values at or above 1 GB use two decimals and base 1000")
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
        #expect(ByteFormatting.string(ByteFormatting.bytesPerGB - 1) == "1000.0 MB")
    }
}
