import Foundation
import ScoloCore

/// Reviews Storage Explorer selections and publishes removal progress.
@MainActor
final class StorageRemovalModel {
    private let settings: SettingsStore?
    let storageExplorer: StorageExplorerModel
    let operations: OperationState
    var canStart: () -> Bool = { true }
    var onRemoval: (() async -> Void)?

    init(settings: SettingsStore? = nil, storageExplorer: StorageExplorerModel, operations: OperationState) {
        self.settings = settings
        self.storageExplorer = storageExplorer
        self.operations = operations
    }

    var storageExplorerRemoveLabel: String {
        guard !storageExplorer.isMapSelectionPending else { return "Move to Trash" }
        let count = storageExplorer.selectedItems.count
        guard count > 0 else { return "Move to Trash" }
        return "Move to Trash (\(ByteFormatting.string(storageExplorer.selectedBytes)))"
    }

    func requestStorageExplorerRemoval() async {
        guard storageExplorer.canRemoveSelection, canStart() else { return }
        let selectedItems = storageExplorer.selectedItems
        operations.removalCompletion = nil
        let presentation = OperationPresentationDuration()
        operations.activity = .reviewingStorageItems(itemCount: selectedItems.count)

        do {
            let review = try await storageExplorer.reviewSelectionForRemoval(selectedItems)
            guard let review else {
                operations.activity = nil
                return
            }
            // Show why removal stopped when the selection fails validation.
            guard review.isReady else {
                operations.activity = nil
                if !review.changedPaths.isEmpty {
                    operations.report(
                        "The Selection Changed",
                        "Some of those items are not what they were when you picked them. "
                            + "Review the updated list and try again."
                    )
                } else if !review.protectedPaths.isEmpty {
                    operations.report(
                        "Some Items Are Protected",
                        "Scolo will not remove some of the selected items. "
                            + "Review the list and try again."
                    )
                } else {
                    // The third way a review is not ready: nothing selected is
                    // still there to remove.
                    operations.report(
                        "Nothing Left to Remove",
                        "The selected items are no longer in this folder."
                    )
                }
                return
            }
            await performStorageExplorerRemoval(review.items, presentation: presentation)
        } catch is CancellationError {
            operations.activity = nil
        } catch {
            operations.activity = nil
            operations.report(
                "The Selection Could Not Be Checked",
                "Scolo could not check the selected items. Nothing was removed."
            )
        }
    }

    private func performStorageExplorerRemoval(
        _ items: [StorageExplorerItem],
        presentation: OperationPresentationDuration
    ) async {
        guard !items.isEmpty else {
            operations.activity = nil
            return
        }
        operations.activity = .removingStorageItems(
            itemCount: items.count,
            totalBytes: items.reduce(0) { $0 + $1.allocatedBytes }
        )

        do {
            let outcome = try await storageExplorer.remove(items, keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt)
            try? await presentation.wait()
            operations.completeTrashRemoval(outcome, in: .storageExplorer)
        } catch is CancellationError {
            storageExplorer.invalidateCache()
        } catch {
            storageExplorer.invalidateCache()
            operations.report(
                "The Items Could Not Be Moved",
                "The selected items could not move to the Trash. Nothing was removed."
            )
        }

        operations.activity = nil
        storageExplorer.refreshEstimatedSnapshot()
        await onRemoval?()
    }

}
