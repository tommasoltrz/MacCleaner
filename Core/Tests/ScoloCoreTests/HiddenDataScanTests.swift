import Foundation
import Testing
@testable import ScoloCore

/// `HiddenDataScanner.scan` against a fixture home.
///
/// The scanner had no test of its own until 20 Sep 2026. It took a home from the
/// day it was written, so nothing stood in the way.
@Suite("Hidden & System Data")
struct HiddenDataScanTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-hidden-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 2 * 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }
    }

    /// `~/.cache` was this scanner's until 20 Sep 2026. System Caches lists it now —
    /// see `SystemCachesScanTests` — and this one only keeps its archive sweep out.
    @Test("~/.cache is not listed here, and a disk image inside it is not swept up")
    func dotCacheBelongsToSystemCaches() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/sometool/index.bin", bytes: 6 * 1024 * 1024)
        try sandbox.file(".cache/vm/disk.qcow2", bytes: 260 * 1024 * 1024)
        try sandbox.file(".somebody/data.bin", bytes: 6 * 1024 * 1024)

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        #expect(result.entries.map(\.url.lastPathComponent) == [".somebody"])
    }

    /// The Trash was a row here. Ticking it and cleaning up asked macOS to move the
    /// Trash into the Trash, or, with that setting off, deleted `~/.Trash` outright
    /// past Empty Trash, its confirmation, its receipts and Put Back.
    @Test("the Trash is never a removable row; the Trash view owns it")
    func trashIsNotOffered() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".Trash/old-report.pdf", bytes: 4 * 1024 * 1024)
        // Large enough for the archive sweep, which must not walk back into the Trash.
        try sandbox.file(".Trash/backup.dmg", bytes: 260 * 1024 * 1024)
        try sandbox.file(".somebody/data.bin", bytes: 6 * 1024 * 1024)

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        #expect(result.entries.map(\.url.lastPathComponent) == [".somebody"])
        #expect(!result.entries.contains { $0.url.path.contains("/.Trash") })
    }

}
