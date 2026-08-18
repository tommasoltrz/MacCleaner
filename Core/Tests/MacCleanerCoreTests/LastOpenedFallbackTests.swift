import Foundation
import Testing
@testable import MacCleanerCore

/// Guards the fallback chain behind the design's **Last opened** column.
///
/// The design renders `Never opened` in orange as "the strongest signal that a file
/// is safe to remove". On macOS 26 `kMDItemLastUsedDate` returns `null` for almost
/// everything — including applications in daily use — so reading it alone made every
/// row claim it had never been opened. A live scan flagged the user's active project
/// directory as safe to delete.
@Suite("Last-opened fallback")
struct LastOpenedFallbackTests {

    /// Minimal conformer: the behaviour under test lives in the protocol extension.
    private struct Probe: CategoryScanner {
        let id: CategoryID = .documentsAndFiles
        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            .empty(id)
        }
    }

    private typealias Sandbox = AllocatedSizeMeasurerTests.Sandbox

    @Test("a freshly written file reports a date rather than never-opened")
    func fileHasADate() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.writeFile("recent.bin", bytes: 1024)

        let date = try #require(
            Probe().lastOpenedDate(for: file),
            "a file modified seconds ago must not render as 'Never opened'"
        )
        #expect(abs(date.timeIntervalSinceNow) < 300)
    }

    @Test("a directory reports a date — folders never carry kMDItemLastUsedDate")
    func directoryHasADate() throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("project/source.swift", bytes: 512)
        let project = sandbox.root.appendingPathComponent("project")

        // This is the case that mislabelled an active project as safe to delete.
        let date = try #require(
            Probe().lastOpenedDate(for: project),
            "a directory must not render as 'Never opened' just because Spotlight has no last-used date"
        )
        #expect(abs(date.timeIntervalSinceNow) < 300)
    }

    @Test("nil is reserved for paths that genuinely do not exist")
    func missingPathIsUnknown() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(Probe().lastOpenedDate(for: missing) == nil)
    }
}
