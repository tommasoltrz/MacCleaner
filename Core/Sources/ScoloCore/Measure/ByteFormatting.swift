import Foundation

/// Byte rendering, defined by the design handoff rather than by `ByteCountFormatter`.
///
/// The handoff fixes the format exactly:
///
///     >= 1 GB  ->  "%.2f GB"
///      < 1 GB  ->  "%.1f MB"
///        zero  ->  "0 B"
///
/// Storage figures use decimal units, as macOS does. One GB is 1,000,000,000 bytes.
/// `ByteCountFormatter` is not used because it can change units and precision.
public enum ByteFormatting {

    public static let bytesPerMB: Int64 = 1_000_000
    public static let bytesPerGB: Int64 = 1_000_000_000

    public static let bytesPerKB: Int64 = 1_000

    /// Renders a byte count as the design specifies.
    ///
    /// The spec gives two branches plus zero, because every value it displays is at
    /// least 1 MB. Taken literally that renders a 200 KB item as `"0.0 MB"`, which a
    /// live scan duly produced. A KB branch is added below 1 MB: it cannot change any
    /// value the design actually shows, and it removes a rendering that reads like a
    /// bug. Sub-megabyte entries are separately filtered out of scan results — see
    /// `ScanCategoryResult.filteringNoise(below:)` — so this is a backstop.
    public static func string(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        if bytes >= bytesPerGB {
            return Self.fixed(Double(bytes) / Double(bytesPerGB), decimals: 2) + " GB"
        }
        if bytes >= bytesPerMB {
            return Self.fixed(Double(bytes) / Double(bytesPerMB), decimals: 1) + " MB"
        }
        return Self.fixed(Double(bytes) / Double(bytesPerKB), decimals: 0) + " KB"
    }

    /// Renders a change in bytes, with the sign in front.
    ///
    /// The minus is U+2212 MINUS SIGN, not the hyphen-minus a keyboard types. At the
    /// weight the Dashboard renders growth figures, a hyphen sits too high and too
    /// short beside a plus sign, and the two signs must read as a pair.
    ///
    /// Zero has no sign: nothing changed, so neither direction is true.
    public static func signedString(_ delta: Int64) -> String {
        if delta == 0 { return "0 B" }
        // `abs` traps on `Int64.min`. The magnitude is a `UInt64`, so clamping it
        // back into `Int64` costs one byte of a figure that cannot occur anyway.
        let magnitude = string(Int64(clamping: delta.magnitude))
        return (delta > 0 ? "+" : "\u{2212}") + magnitude
    }

    /// The same rendering over binary units, labelled the way Apple labels them.
    ///
    /// For iCloud only. `brctl` reports bytes where iCloud's own pages say
    /// "200 GB" for exactly 200 GiB, and the plan tiers are stored that way; run
    /// through the decimal formatter, the user's "200 GB" plan read "214.75 GB".
    /// On-disk figures stay decimal, as Finder shows them.
    public static func binaryString(_ bytes: Int64) -> String {
        let gib: Int64 = 1024 * 1024 * 1024
        let mib: Int64 = 1024 * 1024
        if bytes == 0 { return "0 B" }
        if bytes >= gib {
            return Self.fixed(Double(bytes) / Double(gib), decimals: 2) + " GB"
        }
        if bytes >= mib {
            return Self.fixed(Double(bytes) / Double(mib), decimals: 1) + " MB"
        }
        return Self.fixed(Double(bytes) / 1024, decimals: 0) + " KB"
    }

    /// Locale-independent fixed-point rendering. Always a period, never a comma —
    /// the UI is a fixed-format spec, not localized prose.
    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
