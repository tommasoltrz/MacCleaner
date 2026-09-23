import Foundation
import Observation
import ScoloCore

/// Owns Trash loading, selection, removal, and restore.
@MainActor
@Observable
final class TrashModel {
    let operations: OperationState
    @ObservationIgnored var onReveal: (() -> Void)?
    @ObservationIgnored var onRemoval: (() async -> Void)?
    @ObservationIgnored var onRestore: (() async -> Void)?

    init(operations: OperationState) { self.operations = operations }

    private let trashService = TrashService()

    private(set) var trashSummary: TrashSummary?

    var selectedTrashItemID: TrashItem.ID?

    private var pendingTrashReveal: CleanupHistoryItem?

    func showInTrash(_ item: CleanupHistoryItem) {
        guard item.state == .availableInTrash, item.trashedURL != nil else { return }
        pendingTrashReveal = item
        selectedTrashItemID = nil
        trashSummary = nil
        onReveal?()
    }

    func loadTrash() async {
        // Everything, largest first. The list is lazy, so row count costs nothing,
        // and a Trash screen that hides items reads as missing files. (The design
        // mock's "showing the 4 largest" was sample data, not a principle.)
        trashSummary = try? await trashService.summary(limit: Int.max)
        if let request = pendingTrashReveal, let url = request.trashedURL {
            pendingTrashReveal = nil
            if let item = trashSummary?.items.first(where: {
                $0.url.standardizedFileURL == url.standardizedFileURL
            }), let identity = request.trashedIdentity, FileIdentity.of(item.url) == identity {
                selectedTrashItemID = item.id
            } else if trashSummary != nil {
                operations.report("Item Not Found", "This item is no longer available in the Trash.")
            }
        }
        if let selectedTrashItemID,
           trashSummary?.items.contains(where: { $0.id == selectedTrashItemID }) != true {
            self.selectedTrashItemID = nil
        }
    }

    func emptyTrash() async {
        guard operations.activity == nil else { return }
        operations.activeSheet = nil
        operations.removalCompletion = nil
        let presentation = OperationPresentationDuration()
        operations.activity = .emptyingTrash(
            itemCount: trashSummary?.itemCount ?? 0,
            totalBytes: trashSummary?.totalBytes ?? 0
        )
        do {
            let result = try await trashService.empty(privilegedFallback: true)
            try? await presentation.wait()
            operations.removalCompletion = OperationState.RemovalCompletion(
                destination: .trash,
                title: result.skipped == 0 ? "Trash emptied" : "Some items remain in Trash",
                detail: result.skipped == 0
                    ? "\(ByteFormatting.string(result.freedBytes)) recovered."
                    : "\(result.skipped) \(result.skipped == 1 ? "item could" : "items could") not be removed.",
                isSuccess: result.skipped == 0
            )
        } catch {
            // Do not pretend. Name the remedy: this is what a denied read looks
            // like, and the permission is the fix.
            operations.report(
                "The Trash Could Not Be Read",
                "Grant Scolo Full Disk Access in System Settings, Privacy & Security, "
                    + "then try again."
            )
        }
        // Re-read under the scrim, so the Trash never lifts it over rows that are
        // gone. The disk walk runs after, on the Dashboard's own skeleton.
        await loadTrash()
        operations.activity = nil
        // Emptying the Trash frees space, so this measurement is a clean-up
        // baseline like any other removal's.
        await onRemoval?()
    }

    func putBack(_ item: TrashItem) async {
        do {
            // The row leaves the Trash list below, which is the whole operations.report.
            try await trashService.putBack(item)
        } catch TrashError.destinationOccupied {
            operations.report(
                "\(item.name) Was Not Put Back",
                "Something is already at the place it came from. "
                    + "Move that aside, or drag this out of the Trash yourself."
            )
        } catch {
            operations.report("\(item.name) Was Not Put Back", "It is still in the Trash.")
        }
        await loadTrash()
        await onRestore?()
    }
}
