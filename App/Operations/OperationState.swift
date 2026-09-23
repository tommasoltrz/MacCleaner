import Foundation
import Observation
import ScoloCore

/// Owns shared operation progress, completion, and notices.
@MainActor
@Observable
final class OperationState {
    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash
        var id: String { rawValue }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    var notice: Notice?

    func report(_ title: String, _ message: String) {
        notice = Notice(title: title, message: message)
    }

    enum Activity: Equatable {
        case cleaningUp(itemCount: Int, totalBytes: Int64)
        case emptyingTrash(itemCount: Int, totalBytes: Int64)
        case removingDuplicateFiles(itemCount: Int, totalBytes: Int64)
        case removingStorageItems(itemCount: Int, totalBytes: Int64)
        case reviewingStorageItems(itemCount: Int)
        case uninstalling(applicationName: String, applicationOnly: Bool, waitingToQuit: Bool)
        case waitingForApplicationsToQuit(names: [String])

        var title: String {
            switch self {
            case .cleaningUp(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .emptyingTrash:
                return "Emptying the Trash"
            case .removingDuplicateFiles(let count, _):
                let files = count == 1 ? "file" : "files"
                return "Moving \(count) duplicate \(files) to the Trash"
            case .removingStorageItems(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .reviewingStorageItems(let count):
                let items = count == 1 ? "item" : "items"
                return "Reviewing \(count) \(items)"
            case .uninstalling(let name, _, let waiting):
                return waiting ? "Waiting for \(name) to quit" : "Uninstalling \(name)"
            case .waitingForApplicationsToQuit(let names):
                return "Waiting for \(ListFormatter.localizedString(byJoining: names)) to quit"
            }
        }

        /// Explains why the current disk operation can take time.
        var detail: String {
            switch self {
            case .cleaningUp(_, let bytes),
                 .emptyingTrash(_, let bytes),
                 .removingStorageItems(_, let bytes):
                return "\(ByteFormatting.string(bytes)). Each item is measured on disk "
                    + "before it goes, so large folders take a moment."
            case .removingDuplicateFiles(_, let bytes):
                // Not measured: re-hashed. The keeper and every chosen copy are read
                // in full again, which is what makes a set of large videos slow.
                return "\(ByteFormatting.string(bytes)). Each copy and its keeper are "
                    + "verified byte for byte before it goes, so large files take a moment."
            case .waitingForApplicationsToQuit:
                return "Save your work if an app asks. Scolo waits for the apps to close."
            case .reviewingStorageItems:
                return "Scolo is checking the selected items before moving them to the Trash."
            case .uninstalling(_, let applicationOnly, let waiting):
                if waiting {
                    return "The application and its helpers are asked to quit. "
                        + "Nothing is removed until they are gone."
                }
                return applicationOnly
                    ? "Related files stay on disk."
                    : "The application moves first. Related data stays if that move fails."
            }
        }
    }

    var activity: Activity?

    struct RemovalCompletion: Identifiable {
        let id = UUID()
        let destination: AppSection
        let title: String
        let detail: String
        var isSuccess = true

        var dismissesAutomatically: Bool {
            isSuccess && (destination == .storageExplorer || destination == .uninstaller || destination == .duplicates)
        }
    }

    var removalCompletion: RemovalCompletion?

    func dismissRemovalCompletion() {
        removalCompletion = nil
    }

    func completeTrashRemoval(_ outcome: CleanupOutcome, in destination: AppSection, extraFailures: Int = 0) {
        let remaining = outcome.failed.count + extraFailures
        let success = remaining == 0 && outcome.removedCount > 0
        let count = outcome.removedCount
        var detail = "\(count) \(count == 1 ? "item" : "items") · \(ByteFormatting.string(outcome.removedBytes))"
        if remaining > 0 {
            detail += "\n\(remaining) \(remaining == 1 ? "item was" : "items were") not removed."
        }
        removalCompletion = RemovalCompletion(
            destination: destination,
            title: success ? "Moved to Trash" : (count > 0 ? "Some items were not removed" : "Nothing was removed"),
            detail: detail,
            isSuccess: success
        )
    }

    var isCleaningUp: Bool {
        if case .cleaningUp? = activity { return true }
        return false
    }

    var isUninstallingApp: Bool {
        if case .uninstalling? = activity { return true }
        return false
    }

    var isRemovingDuplicateFiles: Bool {
        if case .removingDuplicateFiles? = activity { return true }
        return false
    }

    var isRemovingStorageItems: Bool {
        if case .removingStorageItems? = activity { return true }
        return false
    }

    var isShowingAppDataAccessAlert = false

    var activeSheet: Sheet?
}
