import Foundation
import Testing
@testable import ScoloCore

/// What the Dashboard's two tiles count, and the rule that they never count the
/// same byte twice.
///
/// The case that forced this suite: an application's caches are children of the
/// application's row, and the Applications category is not safe, so "Safe to
/// remove" could not see a single one of them — while the Scanner, one screen
/// away, badged each of them `regenerable`.
@Suite("Safe to remove and Needs review partition the scan")
struct TileArithmeticTests {

    private static func child(
        _ name: String, bytes: Int64, regenerable: Bool,
        protection: FileEntry.ProtectionReason? = nil
    ) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            kind: regenerable ? .cache : .folder,
            allocatedBytes: bytes,
            isRegenerable: regenerable,
            protectionReason: protection
        )
    }

    private static func application(
        bytes: Int64, children: [FileEntry], protection: FileEntry.ProtectionReason? = nil
    ) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            kind: .appBundle,
            allocatedBytes: bytes,
            isRegenerable: false,
            protectionReason: protection,
            children: children
        )
    }

    /// Every byte a category offers lands in exactly one tile.
    private static func isPartition(_ category: ScanCategoryResult) -> Bool {
        let offered = category.entries.reduce(Int64(0)) { $0 + $1.displayBytes }
        return category.safeToRemoveBytes + category.needsReviewBytes == offered
    }

    @Test("an application's caches are safe; its bundle and data are not")
    func applicationCachesAreSafe() {
        let app = Self.application(bytes: 500, children: [
            Self.child("Caches", bytes: 300, regenerable: true),
            Self.child("Application Support", bytes: 200, regenerable: false,
                       protection: .userData)
        ])
        let category = ScanCategoryResult(categoryID: .applications, entries: [app])

        #expect(category.safeToRemoveBytes == 300)
        // The bundle, and not the user data: that child is locked, so it was never
        // part of what removal could offer in the first place.
        #expect(category.needsReviewBytes == 500)
        #expect(Self.isPartition(category))
    }

    @Test("a running application still yields its caches")
    func runningApplicationYieldsItsCaches() {
        let app = Self.application(
            bytes: 500,
            children: [Self.child("Caches", bytes: 300, regenerable: true)],
            protection: .running
        )
        let category = ScanCategoryResult(categoryID: .applications, entries: [app])

        // The bundle cannot be removed while it runs, so it offers nothing; the
        // caches beside it are ordinary folders and can go.
        #expect(category.safeToRemoveBytes == 300)
        #expect(category.needsReviewBytes == 0)
        #expect(Self.isPartition(category))
    }

    @Test("a locked cache child is nobody's to remove")
    func lockedChildIsNotSafe() {
        let app = Self.application(bytes: 500, children: [
            // Regenerable and locked at once — a manual-removal aggregate, or data
            // the user chose to protect. The badge does not override the lock.
            Self.child("Caches", bytes: 300, regenerable: true, protection: .userData)
        ])
        let category = ScanCategoryResult(categoryID: .applications, entries: [app])

        #expect(category.safeToRemoveBytes == 0)
        #expect(category.needsReviewBytes == 500)
        #expect(Self.isPartition(category))
    }

    @Test("a safe category's regenerable row still counts whole")
    func safeCategoryUnchanged() {
        let derived = FileEntry(
            url: URL(fileURLWithPath: "/tmp/DerivedData"), kind: .cache,
            allocatedBytes: 100, isRegenerable: true
        )
        let archive = FileEntry(
            url: URL(fileURLWithPath: "/tmp/App.xcarchive"), kind: .cache,
            allocatedBytes: 40, isRegenerable: false
        )
        let category = ScanCategoryResult(
            categoryID: .xcode, totalBytes: 140, entries: [derived, archive]
        )

        #expect(category.safeToRemoveBytes == 100)
        #expect(category.needsReviewBytes == 40)
        #expect(Self.isPartition(category))
    }

    @Test("a non-regenerable row in a safe category still gives up its caches")
    func regenerableChildOfANonSafeRow() {
        let archive = FileEntry(
            url: URL(fileURLWithPath: "/tmp/App.xcarchive"), kind: .cache,
            allocatedBytes: 40, isRegenerable: false,
            children: [Self.child("Logs", bytes: 10, regenerable: true)]
        )
        let category = ScanCategoryResult(categoryID: .xcode, entries: [archive])

        #expect(category.safeToRemoveBytes == 10)
        #expect(category.needsReviewBytes == 40)
        #expect(Self.isPartition(category))
    }

    @Test("application leftovers stay wholly safe and wholly outside review")
    func leftoversAreUnaffected() {
        let leftover = FileEntry(
            url: URL(fileURLWithPath: "/tmp/com.gone.app.plist"), kind: .file,
            allocatedBytes: 90, isRegenerable: false
        )
        let category = ScanCategoryResult(
            categoryID: .applicationLeftovers, entries: [leftover]
        )

        #expect(category.safeToRemoveBytes == 90)
        #expect(category.needsReviewBytes == 0)
    }

    @Test("a category that reports a total without rows keeps it under review")
    func rowlessCategoryKeepsItsTotal() {
        // Docker reports from its own accounting and has nothing to break into rows.
        let category = ScanCategoryResult(categoryID: .docker, totalBytes: 5_000)

        #expect(category.safeToRemoveBytes == 0)
        #expect(category.needsReviewBytes == 5_000)
    }
}
