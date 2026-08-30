import Foundation
import Testing
@testable import ScoloCore

@Suite("Scanner category presentation")
struct ScanCategoryPresentationTests {

    @Test("application totals separate installed and removable space")
    func applicationTotals() {
        let cache = FileEntry(
            url: URL(filePath: "/Users/me/Library/Caches/com.example.Editor"),
            kind: .cache,
            allocatedBytes: 300_000_000,
            isRegenerable: true
        )
        let app = FileEntry(
            url: URL(filePath: "/Applications/Editor.app"),
            kind: .appBundle,
            allocatedBytes: 1_200_000_000,
            children: [cache]
        )
        let result = ScanCategoryResult(
            categoryID: .applications,
            totalBytes: app.displayBytes,
            entries: [app]
        )

        #expect(result.applicationInstalledBytes == 1_200_000_000)
        #expect(result.totalBytes == 1_500_000_000)
        #expect(app.rowDisplayBytes == 1_200_000_000)
    }

    @Test("synthetic leftover rows show their child total")
    func leftoverRowSize() {
        let child = FileEntry(
            url: URL(filePath: "/Users/me/Library/Caches/com.example.Gone"),
            kind: .cache,
            allocatedBytes: 300_000_000,
            isRegenerable: true
        )
        let group = FileEntry(
            url: child.url,
            displayName: "com.example.Gone",
            kind: .folder,
            allocatedBytes: 0,
            removalAction: .orphanedApplication(bundleIdentifier: "com.example.Gone"),
            children: [child]
        )

        #expect(group.rowDisplayBytes == 300_000_000)
    }

    @Test("an ordinary parent row shows its complete removal size")
    func ordinaryParentRowSize() {
        let dependency = FileEntry(
            url: URL(filePath: "/Users/me/Documents/Editor/node_modules"),
            kind: .cache,
            allocatedBytes: 300_000_000,
            isRegenerable: true
        )
        let project = FileEntry(
            url: URL(filePath: "/Users/me/Documents/Editor"),
            kind: .folder,
            allocatedBytes: 200_000_000,
            children: [dependency]
        )

        #expect(project.rowDisplayBytes == 500_000_000)
    }

    @Test("other categories have no installed application total")
    func nonApplicationTotal() {
        let result = ScanCategoryResult(categoryID: .documentsAndFiles)
        #expect(result.applicationInstalledBytes == nil)
    }
}
