import Foundation

/// Finds exact application-owned paths that have no current application owner.
public struct ApplicationLeftoversScanner: CategoryScanner {
    public let id = CategoryID.applicationLeftovers

    private let planner: OrphanedAppLeftoverPlanner

    public init() {
        planner = OrphanedAppLeftoverPlanner()
    }

    init(planner: OrphanedAppLeftoverPlanner) {
        self.planner = planner
    }

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let plan = try await planner.plan(
            context: context,
            registeredApplicationBundleIdentifiers:
                context.registeredApplicationBundleIdentifiers,
            candidates: context.applicationLeftoverCandidates
        )
        let entries = plan.groups.compactMap { group -> FileEntry? in
            guard let firstItem = group.items.first else { return nil }
            // The group is the review and removal unit. Child rows only show
            // which files the selected group contains.
            let children = group.items.map(\.fileEntry)
            return FileEntry(
                url: firstItem.url,
                displayName: group.bundleIdentifier,
                parentDisplay: "No installed application owner",
                kind: .folder,
                allocatedBytes: 0,
                removalAction: .orphanedApplication(
                    bundleIdentifier: group.bundleIdentifier
                ),
                childCount: children.count,
                children: children
            )
        }

        let availability: CategoryAvailability = if entries.isEmpty,
                                                     plan.unreadableCount > 0 {
            .unavailable(
                reason: "MacCleaner cannot read other application data. Allow access "
                    + "in System Settings › Privacy & Security. Then scan again."
            )
        } else if entries.isEmpty {
            .empty
        } else {
            .available
        }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: plan.totalBytes,
            entries: entries,
            availability: availability,
            unreadableCount: plan.unreadableCount,
            applicationLeftoverPlan: plan
        )
    }
}
