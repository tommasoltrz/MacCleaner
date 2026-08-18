import Foundation

/// Byte rendering, defined by the design handoff rather than by `ByteCountFormatter`.
///
/// The handoff fixes the format exactly:
///
///     >= 1 GB  ->  "%.2f GB"
///      < 1 GB  ->  "%.1f MB"
///        zero  ->  "0 B"
///
/// and specifies **base 1024** ("the design's numbers assume it"). `ByteCountFormatter`
/// is not used because its `.binary` style renders "8.42 GB" as "8.42 GB" on some
/// locales and "8,42 GB" on others, and it switches units on its own thresholds —
/// neither is acceptable when the spec lists literal expected strings.
public enum ByteFormatting {

    public static let bytesPerMB: Int64 = 1024 * 1024
    public static let bytesPerGB: Int64 = 1024 * 1024 * 1024

    public static let bytesPerKB: Int64 = 1024

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

    /// Locale-independent fixed-point rendering. Always a period, never a comma —
    /// the UI is a fixed-format spec, not localized prose.
    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
