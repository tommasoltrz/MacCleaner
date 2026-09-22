import Foundation
import Testing
@testable import ScoloCore

@Suite("Cleanup action scope")
struct CleanupSelectionTests {
    private func entry(_ name: String, safe: Bool, children: [FileEntry] = []) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/tmp/cleanup-selection/\(name)"),
            kind: safe ? .cache : .folder,
            allocatedBytes: 100,
            isRegenerable: safe,
            children: children
        )
    }

    @Test("Safe cleanup excludes selected review items and unknown paths")
    func isolatesSafeAction() {
        let cache = entry("cache", safe: true)
        let archive = entry("archive", safe: false)
        let category = ScanCategoryResult(categoryID: .xcode, entries: [cache, archive])
        let selected: Set<String> = [cache.id, archive.id, "/tmp/stale"]
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .safe) == [cache.id])
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .review) == [archive.id])
    }

    @Test("Safe child selections remain separate from their review parent")
    func isolatesChildren() {
        let cache = entry("cache", safe: true)
        let data = entry("data", safe: false)
        let parent = entry("parent", safe: false, children: [cache, data])
        let category = ScanCategoryResult(categoryID: .applications, entries: [parent])
        let selected: Set<String> = [cache.id, data.id]
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .safe) == [cache.id])
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .review) == [data.id])
    }

    @Test("Deselected safe items stay excluded")
    func respectsDeselection() {
        let cache = entry("cache", safe: true)
        let category = ScanCategoryResult(categoryID: .systemCaches, entries: [cache])
        #expect(CleanupSelection.ids(in: [category], selected: [], scope: .safe).isEmpty)
    }

    @Test("An individual safe child can be removed without its parent")
    func selectsSafeChild() {
        let child = entry("child", safe: true)
        let parent = entry("parent", safe: true, children: [child])
        let category = ScanCategoryResult(categoryID: .systemCaches, entries: [parent])
        #expect(CleanupSelection.ids(
            in: [category], selected: [child.id], scope: .safe
        ) == [child.id])
    }

    @Test("Locked rows cannot enter safe cleanup")
    func rejectsLockedRows() {
        let cache = FileEntry(
            url: URL(fileURLWithPath: "/tmp/cleanup-selection/protected"),
            kind: .cache, allocatedBytes: 100, isRegenerable: true,
            protectionReason: .userData
        )
        let category = ScanCategoryResult(categoryID: .systemCaches, entries: [cache])
        #expect(CleanupSelection.ids(in: [category], selected: [cache.id], scope: .safe).isEmpty)
    }

    @Test("Selected parents prevent duplicate child removal")
    func removesCoveredChildren() {
        let child = entry("child", safe: true)
        let parent = entry("parent", safe: true, children: [child])
        let category = ScanCategoryResult(categoryID: .systemCaches, entries: [parent])
        #expect(CleanupSelection.ids(
            in: [category], selected: [parent.id, child.id], scope: .all
        ) == [parent.id])
    }

    @Test("A stale app selection cannot hide a selected cache")
    func ignoresApplicationBundles() {
        let cache = entry("cache", safe: true)
        let app = FileEntry(
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            kind: .appBundle, allocatedBytes: 100, children: [cache]
        )
        let category = ScanCategoryResult(categoryID: .applications, entries: [app])
        #expect(CleanupSelection.ids(
            in: [category], selected: [app.id, cache.id], scope: .all
        ) == [cache.id])
    }
}
