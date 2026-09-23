import Foundation
import Observation
import ScoloCore

/// Owns photo scans, grouping, selection, previews, and deletion state.
@MainActor
@Observable
final class PhotoDuplicatesModel {
    struct Preview: Identifiable {
        let groupID: String
        let asset: PhotoAsset
        var id: String { asset.id }
    }

    @ObservationIgnored private let service: PhotoDuplicateService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onFailure: ((String, String) -> Void)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var regroupID: UUID?

    init(service: PhotoDuplicateService? = nil, defaults: UserDefaults = .standard) {
        self.service = service ?? PhotoDuplicateService(
            library: PhotoKitLibrary(),
            visionRevision: UInt32(PhotoKitLibrary.featurePrintRevision)
        )
        self.defaults = defaults
        self.similarity = defaults.string(forKey: "photoSimilarity")
            .flatMap(PhotoSimilarity.init(rawValue:)) ?? .default
    }

    var preview: Preview?
    let thumbnails = PhotoThumbnailLoader()
    private(set) var results: PhotoDuplicateResults?
    private(set) var progress: PhotoDuplicateService.Progress?
    private(set) var isScanning = false
    private(set) var isDeleting = false
    private(set) var selection: Set<String> = []
    private(set) var unavailableReason: String?

    var similarity: PhotoSimilarity {
        didSet {
            guard similarity != oldValue else { return }
            defaults.set(similarity.rawValue, forKey: "photoSimilarity")
            regroup()
        }
    }

    private(set) var isRegrouping = false
    @ObservationIgnored private var regroupTask: Task<Void, Never>?

    var groups: [DuplicateGroup] {
        guard let results else { return [] }
        return results.groups.sorted {
            // Keep groups in place when the user chooses another photo to keep.
            switch ($0.assets.first?.creationDate, $1.assets.first?.creationDate) {
            case let (left?, right?): left == right ? $0.id < $1.id : left > right
            case (nil, _?):           false
            case (_?, nil):           true
            case (nil, nil):          $0.id < $1.id
            }
        }
    }

    var removeLabel: String {
        let count = selection.count
        guard count > 0 else { return "Delete Photos" }
        return "Delete \(count) \(count == 1 ? "Photo" : "Photos")"
    }

    func startScan() {
        guard !isScanning, !isDeleting else { return }
        cancelRegroup()
        // Each scan uses the setting captured when it starts.
        let similarity = similarity
        let requestID = UUID()
        scanID = requestID
        isScanning = true
        progress = nil
        unavailableReason = nil
        selection.removeAll()

        scanTask = Task { [weak self] in
            guard let self else { return }
            let presentation = OperationPresentationDuration()
            defer {
                if self.scanID == requestID {
                    self.isScanning = false
                    self.scanTask = nil
                    self.scanID = nil
                }
            }
            do {
                let results = try await service.sweep(
                    similarity: similarity,
                    onProgress: { progress in
                        Task { @MainActor in
                            guard self.scanID == requestID else { return }
                            self.progress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.scanID == requestID else { return }
                self.results = results
                self.selection = Self.defaultSelection(for: results)
                // The results page counts the sets, the photos and what was skipped.
            } catch let unavailable as PhotoSweepUnavailable {
                guard self.scanID == requestID, !Task.isCancelled else { return }
                // Shown on the page, with what to do about it.
                self.unavailableReason = Self.describe(unavailable)
            } catch is CancellationError {
                // The user stopped it.
            } catch {
                guard self.scanID == requestID, !Task.isCancelled else { return }
                self.onFailure?(
                    "The Photo Sweep Did Not Finish",
                    "Scolo could not finish comparing the library. Nothing was deleted; "
                        + "try again."
                )
            }
            try? await presentation.wait()
        }
    }

    private func regroup() {
        guard results != nil, !isScanning else { return }
        cancelRegroup()
        let requestID = UUID()
        regroupID = requestID
        let similarity = similarity
        isRegrouping = true

        regroupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.regroupID == requestID {
                    self.isRegrouping = false
                    self.regroupTask = nil
                    self.regroupID = nil
                }
            }
            do {
                guard let results = try await service.regroup(similarity: similarity) else {
                    return
                }
                // Only the current regroup task can publish results.
                try Task.checkCancellation()
                guard self.regroupID == requestID, similarity == self.similarity else { return }
                self.results = results
                // Reset selection because the new groups can have different keepers.
                self.selection = Self.defaultSelection(for: results)
            } catch is CancellationError {
                // Superseded by a later change, or the user left.
            } catch {
                guard self.regroupID == requestID, !Task.isCancelled else { return }
                self.onFailure?(
                    "The Photos Could Not Be Regrouped",
                    "Scolo could not apply that setting to the sweep it has. "
                        + "Scan again to use it."
                )
            }
        }
    }

    private func cancelRegroup() {
        regroupTask?.cancel()
        regroupID = nil
        regroupTask = nil
        isRegrouping = false
    }

    func cancelScan() {
        scanTask?.cancel()
        scanID = nil
        scanTask = nil
        isScanning = false
        progress = nil
    }

    private static func describe(_ unavailable: PhotoSweepUnavailable) -> String {
        switch unavailable {
        case .access(let access):
            access.unavailableReason ?? "The photo library is unavailable."
        case .librarySyncing(let count):
            "Only \(count) photos have arrived from iCloud so far. Let Photos finish "
                + "syncing — sweeping now would compare photos against copies that are "
                + "not here yet."
        }
    }

    func selectAll() {
        selection = Set(groups.flatMap(\.removable).map(\.id))
    }

    private static func defaultSelection(for results: PhotoDuplicateResults) -> Set<String> {
        Set(
            results.groups
                .filter { $0.kind != .similar }
                .flatMap(\.removable)
                .map(\.id)
        )
    }

    func deselectAll() { selection.removeAll() }

    func keepInstead(groupID: String, assetID: String) {
        guard var results = results,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(assetID)
        else { return }

        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        self.results = results

        selection.remove(assetID)
        // Select the previous keeper only when other copies remain selected.
        if promoted.removable.contains(where: { selection.contains($0.id) }) {
            selection.insert(previousKeeper)
        }
    }

    func setSelected(_ isSelected: Bool, assetID: String) {
        guard results?.groups.contains(where: { $0.removable.contains(where: { $0.id == assetID }) }) == true else { return }
        if isSelected {
            selection.insert(assetID)
        } else {
            selection.remove(assetID)
        }
    }

    func toggle(_ assetID: String) {
        setSelected(!selection.contains(assetID), assetID: assetID)
    }

    func isGroupSelected(_ groupID: String) -> Bool {
        guard let group = results?.groups.first(where: { $0.id == groupID }) else { return false }
        return !group.removable.isEmpty && group.removable.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ groupID: String) {
        guard let group = results?.groups.first(where: { $0.id == groupID }) else { return }
        let ids = group.removable.map(\.id)
        if isGroupSelected(groupID) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func deleteSelected(onCompletion: (Int) -> Void) async {
        guard !isScanning, !isDeleting, !isRegrouping else { return }
        let removableIDs = Set(groups.flatMap(\.removable).map(\.id))
        let ids = Array(selection.intersection(removableIDs))
        guard !ids.isEmpty else { return }
        isDeleting = true
        let presentation = OperationPresentationDuration()
        preview = nil
        defer { isDeleting = false }

        do {
            try await service.delete(assetIDs: ids)
            let gone = Set(ids)
            // Remove deleted copies and groups that have no remaining duplicates.
            if var results = results {
                results.groups = results.groups.compactMap { group in
                    let remaining = group.removable.filter { !gone.contains($0.id) }
                    guard !remaining.isEmpty else { return nil }
                    return DuplicateGroup(
                        id: group.id, kind: group.kind, keeper: group.keeper, removable: remaining
                    )
                }
                self.results = results
            }
            selection.removeAll()
            try? await presentation.wait()
            onCompletion(ids.count)
        } catch is CancellationError {
            // Keep the selection when the user declines the Photos request.
        } catch {
            // Report deletion failures without clearing the selection.
            onFailure?(
                "Those Photos Were Not Deleted",
                "Photos refused the deletion. Nothing was removed from the library."
            )
        }
    }
}
