import Foundation
import Testing
@testable import ScoloCore

@Suite("Storage rule registry")
struct StorageRuleRegistryTests {
    private let home = URL(fileURLWithPath: "/registry-test-home")

    private func rule(
        _ id: String, path: String, owner: String = "Example",
        type: StorageRule.DataType = .cache,
        basis: StorageRule.Evidence.Basis = .sourceReview
    ) -> StorageRule {
        StorageRule(
            id: id, path: path, owner: owner, ownerRules: [.bundleIdentifier("com.example." + owner)],
            category: .aiTools, dataType: type, summary: "Example storage",
            removalEffect: "Requires another download.", evidence: .init(basis: basis, reference: "Test fixture")
        )
    }

    @Test("The catalog has unique IDs, valid paths, and explicit evidence")
    func catalogIntegrity() {
        let rules = StorageRuleRegistry.standard(home: home).rules
        #expect(!rules.isEmpty)
        #expect(Set(rules.map(\.id)).count == rules.count)
        #expect(rules.allSatisfy { $0.isValid })
        #expect(rules.allSatisfy { !$0.evidence.reference.isEmpty })
        #expect(rules.contains { $0.evidence.basis == .sourceReview && $0.dataType == .downloadedTools })
        #expect(rules.contains { $0.evidence.basis == .inheritedRule })
    }

    @Test("Specific cache paths override protected parents without including sibling profile data")
    func specificityAndBoundaries() {
        let parent = rule("data", path: "Library/App", type: .userData)
        let cache = rule("cache", path: "Library/App/Profile */Code Cache")
        let exact = rule("special", path: "Library/App/Profile 1/Code Cache", type: .userData)
        let registry = StorageRuleRegistry(rules: [parent, cache, exact])
        #expect(registry.resolve(home.appendingPathComponent("Library/App/Profile 2/Code Cache/file"), home: home) == .known(cache))
        #expect(registry.resolve(home.appendingPathComponent("Library/App/Profile 1/Code Cache"), home: home) == .known(exact))
        for sibling in ["Cookies", "Local Storage", "Service Worker", "Shared Dictionary"] {
            #expect(registry.resolve(home.appendingPathComponent("Library/App/Profile 2/" + sibling), home: home) == .known(parent))
        }
        #expect(registry.resolve(home.appendingPathComponent("Library/AppBackup"), home: home) == .unknown)
        #expect(registry.resolve(home.appendingPathComponent("Library/App/Profile 2/nested/Code Cache"), home: home) == .known(parent))
    }

    @Test("Equally specific owners create a locked conflict regardless of rule order")
    func conflictingOwners() {
        let first = rule("first", path: "cache")
        let second = rule("second", path: "cache", owner: "Other")
        let entry = FileEntry(url: home.appendingPathComponent("cache"), kind: .cache, allocatedBytes: 10, isRegenerable: true)
        for rules in [[first, second], [second, first]] {
            let registry = StorageRuleRegistry(rules: rules)
            #expect(registry.resolve(entry.url, home: home) == .conflict([first, second]))
            let classified = registry.classify(entry, home: home, context: ScanContext())
            #expect(classified.isRemovalLocked)
            #expect(!classified.regeneratesSafely)
            #expect(!CleanupService.removalAllowed(classified, userDataRemovalOverrides: [classified.id]))
        }
    }

    @Test("Unverified rules cannot become safe through a cache label")
    func unverifiedRule() {
        let rule = rule("unverified", path: "cache", basis: .unverified)
        let original = FileEntry(url: home.appendingPathComponent("cache"), kind: .cache, allocatedBytes: 10, isRegenerable: true)
        var entry = StorageRuleRegistry(rules: [rule]).classify(original, home: home, context: ScanContext())
        #expect(!entry.isRegenerable)
        #expect(entry.safeRemovalReviewReason != nil)
        #expect(entry.storageRule == rule)
        entry.isRegenerable = true
        #expect(!entry.regeneratesSafely)
        #expect(ScanCategoryResult(categoryID: .aiTools, entries: [entry]).safeToRemoveBytes == 0)
    }

    @Test("A parent cache cannot bypass a more specific protected folder")
    func protectedDescendant() {
        let parent = rule("cache", path: "cache")
        let child = rule("data", path: "cache/saved", type: .userData)
        let registry = StorageRuleRegistry(rules: [parent, child])
        let original = FileEntry(url: home.appendingPathComponent("cache"), kind: .cache, allocatedBytes: 10)
        let entry = registry.classify(original, home: home, context: ScanContext())
        #expect(entry.isRemovalLocked)
        #expect(!entry.regeneratesSafely)
        #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
    }

    @Test("Registry metadata drives category, description, regeneration, and live ownership")
    func sharedConsumers() throws {
        let registry = StorageRuleRegistry.standard(home: home)
        let url = home.appendingPathComponent(".cache/codex-runtimes")
        let original = FileEntry(url: url, kind: .cache, allocatedBytes: 10)
        let entry = registry.classify(original, home: home, context: ScanContext())
        let rule = try #require(entry.storageRule)
        #expect(rule.category == .aiTools)
        #expect(rule.evidence.basis == .sourceReview)
        #expect(entry.displayName == "Codex · Downloaded runtime")
        #expect(FileEntryPresentation(entry: entry).summary.contains("another download"))
        #expect(entry.regeneratesSafely)
        let owner = FileEntry.RunningOwner(name: "Codex", bundleIdentifier: "com.openai.codex", bundlePath: "/Codex.app")
        let running = ScanContext(runningApplications: [owner])
        #expect(running.runningOwner(for: entry) == owner)
        #expect(!registry.classify(original, home: home, context: running).regeneratesSafely)
    }

    @Test("Invalid rules and paths outside the home do not match")
    func invalidPaths() {
        for path in ["../outside", "/cache", "cache//data", "cache/**/data", "cache/./data"] {
            let rule = rule("invalid", path: path)
            #expect(!rule.isValid)
            #expect(StorageRuleRegistry(rules: [rule]).resolve(home.appendingPathComponent("cache/data"), home: home) == .unknown)
        }
        let registry = StorageRuleRegistry(rules: [rule("cache", path: "cache")])
        #expect(registry.resolve(URL(fileURLWithPath: "/elsewhere/cache"), home: home) == .unknown)
    }

    @Test("Symbolic links cannot inherit a cache classification")
    func symbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scolo-registry-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("data"))
        let link = root.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let registry = StorageRuleRegistry(rules: [rule("cache", path: "cache")])
        #expect(registry.resolve(link, home: root) == .unknown)
        #expect(registry.resolve(link.appendingPathComponent("data"), home: root) == .unknown)
    }
}
