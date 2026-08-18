import Foundation
import Testing
@testable import MacCleanerCore

/// Categories must never claim the same bytes twice.
///
/// This is not hypothetical. The Electron predecessor counted
/// `~/Library/Caches/Homebrew` in both "App Data & Caches" and "Package Caches",
/// which inflated its totals and made the unattributed remainder look smaller than
/// it was. When the seven scanners were ported in parallel, the same overlap
/// reappeared on `Yarn`, `pnpm` and `ms-playwright` — two independent authors each
/// reasonably claiming the same directory.
///
/// A double-counted byte is worse than a cosmetic error: it is offered to the user
/// twice, so cleaning one category silently falsifies the other's figure and the
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
    /// (`~/.cache/yarn`, `~/.cache/ms-playwright`) were removed from
    /// `PackageManagerScanner` at integration for exactly this reason.
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

    @Test("only Xcode's own categories are marked safe to remove")
    func safeCategoriesAreTheRegenerableOnes() {
        // Drives the Dashboard's "Safe to remove" tile, which promises the contents
        // regenerate on demand and need no human judgement.
        #expect(CategoryID.systemCaches.isSafe)
        #expect(CategoryID.packageManagers.isSafe)
        #expect(CategoryID.xcode.isSafe)

        #expect(!CategoryID.documentsAndFiles.isSafe)
        #expect(!CategoryID.applications.isSafe)
        #expect(!CategoryID.hiddenSystemData.isSafe)
        #expect(!CategoryID.docker.isSafe)
    }
}
