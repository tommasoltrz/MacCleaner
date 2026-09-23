import Foundation
import Observation
import ScoloCore

/// Owns file scans, duplicate selection, and duplicate removal.
@MainActor
@Observable
final class FileDuplicatesModel {
    @ObservationIgnored private let settings: SettingsStore?
    let operations: OperationState
    @ObservationIgnored var canStart: () -> Bool = { true }
    @ObservationIgnored var onRemoval: (() async -> Void)?
    @ObservationIgnored private var currentScanID: UUID?
    private var isCancellingScan = false

    init(settings: SettingsStore? = nil, operations: OperationState, scanner: any FileDuplicateScanning = FileDuplicateService()) {
        self.settings = settings
        self.fileDuplicateService = scanner
        self.operations = operations
    }

    private var keepReceipt: Bool { settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt }

    private let fileDuplicateService: any FileDuplicateScanning

    private let fileDuplicateRemovalService = FileDuplicateRemovalService()

    @ObservationIgnored private var fileDuplicateTask: Task<Void, Never>?

    private(set) var fileDuplicateResults: FileDuplicateResults?

    private(set) var fileDuplicateProgress: FileDuplicateService.Progress?

    private(set) var isScanningDuplicateFiles = false

    var fileDuplicateSelection: Set<DuplicateFile.ID> = []

    var fileDuplicateMinimumBytes: Int64 = 1_000_000 {
        didSet {
            let visibleIDs = Set(fileDuplicateGroups.flatMap(\.removable).map(\.id))
            fileDuplicateSelection.formIntersection(visibleIDs)
        }
    }

    var fileDuplicateGroups: [FileDuplicateGroup] {
        (fileDuplicateResults?.groups ?? []).filter {
            $0.keeper.logicalBytes >= fileDuplicateMinimumBytes
        }
    }

    var fileDuplicateSelectionBytes: Int64 {
        fileDuplicateGroups
            .flatMap(\.removable)
            .filter { fileDuplicateSelection.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    var fileDuplicateRemoveLabel: String {
        let count = fileDuplicateSelection.count
        guard count > 0 else { return "Move to Trash" }
        return "Move to Trash (\(ByteFormatting.string(fileDuplicateSelectionBytes)))"
    }

    func startFileDuplicateScan(roots: [URL]? = nil) {
        guard !isScanningDuplicateFiles, operations.activity == nil, canStart() else { return }
        let scanRoots = roots ?? fileDuplicateResults?.roots ?? []
        if scanRoots.isEmpty {
            return
        }

        isCancellingScan = false
        isScanningDuplicateFiles = true
        fileDuplicateProgress = .init(stage: .enumerating)
        fileDuplicateSelection.removeAll()

        let scanID = UUID()
        currentScanID = scanID
        fileDuplicateTask = Task { [weak self] in
            guard let self else { return }
            let presentation = OperationPresentationDuration()
            defer {
                self.isScanningDuplicateFiles = false
                self.fileDuplicateTask = nil
                self.currentScanID = nil
            }
            do {
                let results = try await fileDuplicateService.scan(
                    roots: scanRoots,
                    // Keep all sizes so the size filter can change without another scan.
                    options: .init(minimumLogicalBytes: 0),
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    onProgress: { progress in
                        Task { @MainActor in
                            guard self.currentScanID == scanID, !self.isCancellingScan else { return }
                            self.fileDuplicateProgress = progress
                        }
                    }
                )
                // The results page counts what was checked and what was found.
                try Task.checkCancellation()
                fileDuplicateResults = results
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                guard !Task.isCancelled else { return }
                operations.report(
                    "The Duplicate Scan Did Not Finish",
                    "Scolo could not finish comparing those folders. Try scanning again."
                )
            }
            try? await presentation.wait()
        }
    }

    func cancelFileDuplicateScan() {
        isCancellingScan = true
        fileDuplicateTask?.cancel()
    }

    func selectAllFileDuplicates() {
        fileDuplicateSelection = Set(fileDuplicateGroups.flatMap(\.removable).map(\.id))
    }

    func deselectAllFileDuplicates() {
        fileDuplicateSelection.removeAll()
    }

    func toggleFileDuplicate(_ fileID: DuplicateFile.ID) {
        if fileDuplicateSelection.contains(fileID) {
            fileDuplicateSelection.remove(fileID)
        } else if fileDuplicateGroups.flatMap(\.removable).contains(where: { $0.id == fileID }) {
            fileDuplicateSelection.insert(fileID)
        }
    }

    func toggleFileDuplicateGroup(_ group: FileDuplicateGroup) {
        let ids = Set(group.removable.map(\.id))
        if ids.isSubset(of: fileDuplicateSelection) {
            fileDuplicateSelection.subtract(ids)
        } else {
            fileDuplicateSelection.formUnion(ids)
        }
    }

    func keepFileInstead(groupID: String, fileID: DuplicateFile.ID) {
        guard var results = fileDuplicateResults,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(fileID)
        else { return }

        let groupWasSelected = results.groups[index].removable.contains {
            fileDuplicateSelection.contains($0.id)
        }
        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        fileDuplicateResults = results
        fileDuplicateSelection.remove(fileID)
        if groupWasSelected { fileDuplicateSelection.insert(previousKeeper) }
    }

    func removeSelectedDuplicateFiles() async {
        let selected = fileDuplicateSelection
        guard !selected.isEmpty, canStart() else { return }
        operations.removalCompletion = nil
        let presentation = OperationPresentationDuration()
        operations.activity = .removingDuplicateFiles(
            itemCount: selected.count,
            totalBytes: fileDuplicateSelectionBytes
        )

        do {
            let result = try await fileDuplicateRemovalService.remove(
                selectedIDs: selected,
                from: fileDuplicateGroups,
                privilegedFallback: true,
                keepReceipt: keepReceipt
            )
            let outcome = result.cleanup
            let failed = Set(outcome.failed)
            let removed = selected.subtracting(failed)
            let noLongerVerified = removed.union(result.staleFileIDs)
            if var results = fileDuplicateResults {
                results.groups = results.groups.compactMap { group in
                    guard !result.staleGroupIDs.contains(group.id) else { return nil }
                    return group.removingFiles(withIDs: noLongerVerified)
                }
                fileDuplicateResults = results
            }
            fileDuplicateSelection.subtract(noLongerVerified)

            try? await presentation.wait()
            operations.completeTrashRemoval(
                outcome, in: .duplicates,
                extraFailures: max(0, selected.count - outcome.removedCount - outcome.failed.count)
            )
            if outcome.permissionDenied.contains(where: ApplicationRuntime.isAppDataPath) {
                operations.isShowingAppDataAccessAlert = true
            }
        } catch is CancellationError {
            // The user stopped it.
        } catch {
            operations.report(
                "The Duplicates Could Not Be Moved",
                "The selected copies could not move to the Trash. Nothing was removed."
            )
        }
        // The completion is ready before the progress surface closes.
        operations.activity = nil
        await onRemoval?()
    }
}
