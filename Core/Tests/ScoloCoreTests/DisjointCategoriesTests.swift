import Foundation
import Testing
@testable import ScoloCore

/// Categories must never claim the same bytes twice.
///
/// This is not hypothetical. The Electron predecessor counted
/// `~/Library/Caches/Homebrew` in both "App Data & Caches" and "Package Caches",
/// which inflated its totals and made the unattributed remainder look smaller than
/// it was. The parallel scanner ports introduced the same overlap on `Yarn`,
/// `pnpm` and `ms-playwright`. Two independent authors each reasonably claimed
/// the same directory.
///
/// A double-counted byte is worse than a cosmetic error. The app offers it twice,
/// so cleaning one category silently falsifies the other category's figure. The
/// Dashboard's "Safe to remove" total overstates what the disk will actually give
/// back.
@Suite("Categories claim disjoint paths")
struct DisjointCategoriesTests {

    /// Everything `PackageManagerScanner` claims directly under `~/Library/Caches`.
    private var packageManagerCacheChildren: Set<String> {
        Set(
            PackageManagerScanner.roots
                .map(\.components)
                .filter { $0.count == 3 && $0[0] == "Library" && $0[1] == "Caches" }
                .map { $0[2] }
        )
    }

    @Test("System Caches skips every ~/Library/Caches root that Package Manager claims")
    func systemCachesSkipsPackageManagerRoots() {
        let claimed = packageManagerCacheChildren
        let skipped = SystemCachesScanner.packageManagerOwnedCacheNames

        let doubleCounted = claimed.subtracting(skipped)
        #expect(
            doubleCounted.isEmpty,
            """
            PackageManagerScanner claims \(doubleCounted.sorted()) under ~/Library/Caches, \
            but SystemCachesScanner does not skip them, so those bytes are counted in \
            both categories. Add them to SystemCachesScanner.packageManagerOwnedCacheNames.
            """
        )
    }

    @Test("the skip list contains nothing Package Manager has stopped claiming")
    func skipListHasNoStaleEntries() {
        let claimed = packageManagerCacheChildren
        let stale = SystemCachesScanner.packageManagerOwnedCacheNames.subtracting(claimed)
        #expect(
            stale.isEmpty,
            """
            SystemCachesScanner skips \(stale.sorted()), but PackageManagerScanner no \
            longer claims them — those caches are now invisible to both categories.
            """
        )
    }

    @Test("package manager cache roots are pairwise disjoint")
    func packageManagerRootsAreDisjoint() {
        let paths = PackageManagerScanner.roots.map { $0.components.joined(separator: "/") }
        for outer in paths {
            for inner in paths where inner != outer {
                #expect(
                    !inner.hasPrefix(outer + "/"),
                    "\(inner) is nested inside \(outer); its bytes would be counted twice"
                )
            }
        }
    }

    /// `HiddenDataScanner` emits `~/.cache` as one entry covering the whole
    /// directory, so no other scanner may claim anything inside it. Two roots
    /// For this reason, the integration removed `~/.cache/yarn` and
    /// `~/.cache/ms-playwright` from `PackageManagerScanner`.
    @Test("no package manager root is nested inside ~/.cache, which Hidden Data owns")
    func nothingNestedInsideDotCache() {
        let nested = PackageManagerScanner.roots
            .filter { $0.components.first == ".cache" && $0.components.count > 1 }
            .map { $0.components.joined(separator: "/") }

        #expect(
            nested.isEmpty,
            """
            \(nested) sit inside ~/.cache, which HiddenDataScanner claims whole. \
            Those bytes would be offered in both Package Manager Caches and \
            Hidden & System Data.
            """
        )
    }

    @Test("application leftovers replace overlapping generic cleanup rows")
    func applicationLeftoversOwnTheirPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/scolo-overlap", isDirectory: true)
        let leftover = root.appendingPathComponent("com.vendor.old", isDirectory: true)
        let unrelated = URL(fileURLWithPath: "/tmp/unrelated-cache", isDirectory: true)
        let leftoverChild = FileEntry(
            url: leftover,
            kind: .cache,
            allocatedBytes: 2_048,
            isRegenerable: true
        )
        let leftoverGroup = FileEntry(
            url: leftover,
            displayName: "com.vendor.old",
            kind: .folder,
            allocatedBytes: 0,
            removalAction: .orphanedApplication(bundleIdentifier: "com.vendor.old"),
            children: [leftoverChild]
        )
        let results = [
            ScanCategoryResult(
                categoryID: .hiddenSystemData,
                totalBytes: 8_192,
                entries: [FileEntry(url: root, kind: .cache, allocatedBytes: 8_192)]
            ),
            ScanCategoryResult(
                categoryID: .systemCaches,
                totalBytes: 6_144,
                entries: [
                    leftoverChild,
                    FileEntry(url: unrelated, kind: .cache, allocatedBytes: 4_096),
                ]
            ),
            ScanCategoryResult(
                categoryID: .applicationLeftovers,
                totalBytes: 2_048,
                entries: [leftoverGroup]
            ),
        ]

        let filtered = ScanCoordinator.removingApplicationLeftoverOverlaps(from: results)
        let hidden = try #require(filtered.first { $0.categoryID == .hiddenSystemData })
        let caches = try #require(filtered.first { $0.categoryID == .systemCaches })

        #expect(hidden.entries.isEmpty)
        #expect(hidden.totalBytes == 0)
        #expect(hidden.availability == .empty)
        #expect(caches.entries.map(\.url) == [unrelated])
        #expect(caches.totalBytes == 4_096)
    }

    @Test("only low-risk categories are safe to remove")
    func safeCategoriesUseVerifiedLowRiskRules() {
        // Cache files regenerate. Application leftovers have no installed owner.
        // These rules drive the Dashboard's "Safe to Remove" tile.
        #expect(CategoryID.applicationLeftovers.isSafe)
        #expect(CategoryID.systemCaches.isSafe)
        #expect(CategoryID.packageManagers.isSafe)
        #expect(CategoryID.xcode.isSafe)

        #expect(!CategoryID.documentsAndFiles.isSafe)
        #expect(!CategoryID.applications.isSafe)
        #expect(!CategoryID.hiddenSystemData.isSafe)
        #expect(!CategoryID.docker.isSafe)
    }
}
