import AppKit
import Foundation
import ScoloCore
import Observation

struct StorageExplorerLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let isInternal: Bool

    var id: String { url.path }
    var symbol: String { isInternal ? "internaldrive" : "externaldrive" }
}

/// Owns one Storage Explorer session and its folder history.
@MainActor
@Observable
final class StorageExplorerModel {
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let service: StorageExplorerService
    @ObservationIgnored private let removalService: StorageExplorerRemovalService
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var cachedSnapshots: [String: StorageExplorerSnapshot] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    /// A row to select as soon as the folder holding it has been measured.
    ///
    /// Every load clears the selection, because a new folder's rows have nothing to
    /// do with the previous folder's. A caller that wants one row picked out
    /// therefore cannot simply write `selection` and navigate: the request has to
    /// travel with the navigation and be applied when the measurement arrives. The
    /// Dashboard's growth report is the one caller — it opens the parent folder and
    /// names the folder that changed.
    @ObservationIgnored private var pendingSelection: URL?

    private static let cacheLimit = 32

    var snapshot: StorageExplorerSnapshot?
    var currentURL: URL?
    var selection = Set<StorageExplorerItem.ID>() {
        didSet { finishMapSelection() }
    }
    private(set) var isMapSelectionPending = false
    @ObservationIgnored private var mapSelectionTask: Task<Void, Never>?
    var isLoading = false
    var progress = SizeMeasurement.zero
    var error: StorageExplorerError?
    var wasCancelled = false
    var locations: [StorageExplorerLocation] = []

    private var history: [URL] = []
    private var forwardHistory: [URL] = []

    init(
        settings: SettingsStore? = nil,
        service: StorageExplorerService = StorageExplorerService(),
        removalService: StorageExplorerRemovalService = StorageExplorerRemovalService()
    ) {
        self.settings = settings
        self.service = service
        self.removalService = removalService
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    var selectedItems: [StorageExplorerItem] {
        let selected = selection
        return snapshot?.items.filter { selected.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.allocatedBytes }
    }

    var canRemoveSelection: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy(\.isRemovable)
    }

    /// Highlight tiles immediately. Delay only the first activation of the header action.
    func selectMapItems(_ ids: Set<StorageExplorerItem.ID>) {
        let wasEnabled = canRemoveSelection && !isMapSelectionPending
        selection = ids
        guard !wasEnabled, canRemoveSelection else { return }
        isMapSelectionPending = true
        mapSelectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) }
            catch { return }
            self?.finishMapSelection()
        }
    }

    func finishMapSelection() {
        mapSelectionTask?.cancel()
        mapSelectionTask = nil
        isMapSelectionPending = false
    }

    func prepareLocations() {
        locations = Self.mountedLocations()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Scolo will measure the folder and its immediate contents."
        panel.prompt = "Explore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        Task { @MainActor in
            guard await panel.presentAsSheet() == .OK, let url = panel.url else { return }
            selectLocation(url)
        }
    }

    /// Drops every cached level. The model clears its own cache after an Explorer
    /// removal; `AppModel` calls this after every other removal, since those move
    /// files the cached levels still count.
    func invalidateCache() {
        clearCache()
    }

    func selectHome() {
        selectLocation(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// - Parameter revealing: a direct child of `url` to select once it is measured.
    func selectLocation(_ url: URL, revealing item: URL? = nil) {
        history.removeAll()
        forwardHistory.removeAll()
        load(url, useCache: false, revealing: item)
    }

    func open(_ item: StorageExplorerItem) {
        guard item.opensAsDirectory, let currentURL else { return }
        history.append(currentURL)
        forwardHistory.removeAll()
        load(item.url)
    }

    func navigate(to url: URL) {
        guard url != currentURL else { return }
        if let currentURL { history.append(currentURL) }
        forwardHistory.removeAll()
        load(url)
    }

    func goBack() {
        guard let target = history.popLast() else { return }
        if let currentURL { forwardHistory.append(currentURL) }
        load(target)
    }

    func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        if let currentURL { history.append(currentURL) }
        load(target)
    }

    func refresh(clearAllCachedFolders: Bool = false) {
        guard let currentURL else { return }
        if clearAllCachedFolders {
            clearCache()
        } else {
            removeCachedSnapshot(for: currentURL)
        }
        load(currentURL, useCache: false)
    }

    func cancel() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isLoading = false
        wasCancelled = true
    }

    func remove(_ items: [StorageExplorerItem], keepReceipt: Bool) async throws -> CleanupOutcome {
        guard let directory = snapshot?.directory else { return CleanupOutcome() }
        return try await removalService.remove(
            items,
            from: directory,
            keepReceipt: keepReceipt
        )
    }

    func reviewSelectionForRemoval(
        _ items: [StorageExplorerItem]
    ) async throws -> StorageExplorerSelectionReview? {
        guard let currentURL else { return nil }
        let review = try await service.reviewSelection(
            items,
            in: currentURL,
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? []
        )
        snapshot = review.snapshot
        store(review.snapshot)
        selection = selection.intersection(Set(review.snapshot.items.map(\.id)))

        return review
    }

    private func load(
        _ url: URL,
        useCache: Bool = true,
        revealing item: URL? = nil
    ) {
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        selection.removeAll()
        // Set on every load, so a navigation that asks for nothing also discards a
        // request the previous navigation never got to apply.
        pendingSelection = item
        progress = .zero
        error = nil
        wasCancelled = false

        if useCache, let cached = cachedSnapshot(for: url) {
            currentURL = cached.directory
            snapshot = cached
            isLoading = false
            scanTask = nil
            applyPendingSelection()
            return
        }

        currentURL = url
        snapshot = nil
        isLoading = true

        let excludedPaths = settings?.excludedFolderPaths ?? []
        let excludedPatterns = settings?.excludedPatterns ?? []
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await service.scan(
                    directory: url,
                    excludedPaths: excludedPaths,
                    excludedPatterns: excludedPatterns,
                    progress: { measurement in
                        // Strong `self`: the task above already holds it for the
                        // whole scan, so a second weak capture only looked like it
                        // was releasing something. A later navigation is ruled out
                        // by the generation, not by the reference.
                        Task { @MainActor in
                            guard self.scanGeneration == generation else { return }
                            self.progress = measurement
                        }
                    }
                )
                guard scanGeneration == generation else { return }
                self.snapshot = snapshot
                store(snapshot)
                currentURL = snapshot.directory
                isLoading = false
                scanTask = nil
                applyPendingSelection()
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                isLoading = false
                scanTask = nil
            } catch let explorerError as StorageExplorerError {
                guard scanGeneration == generation else { return }
                error = explorerError
                isLoading = false
                scanTask = nil
            } catch {
                guard scanGeneration == generation else { return }
                self.error = .unavailable(url.path)
                isLoading = false
                scanTask = nil
            }
        }
    }

    /// Selects the requested row, if the measurement found it.
    ///
    /// The request is consumed either way: a folder that was removed between the
    /// report and the click is simply not there, and the Explorer shows its parent
    /// rather than pretending otherwise.
    private func applyPendingSelection() {
        guard let pending = pendingSelection, let snapshot else { return }
        pendingSelection = nil
        let path = pending.standardizedFileURL.path
        guard let item = snapshot.items.first(
            where: { $0.url.standardizedFileURL.path == path }
        ) else { return }
        selection = [item.id]
    }

    private func cachedSnapshot(for url: URL) -> StorageExplorerSnapshot? {
        let key = Self.cacheKey(for: url)
        guard let snapshot = cachedSnapshots[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return snapshot
    }

    private func store(_ snapshot: StorageExplorerSnapshot) {
        let key = Self.cacheKey(for: snapshot.directory)
        cachedSnapshots[key] = snapshot
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > Self.cacheLimit {
            cachedSnapshots.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func clearCache() {
        cachedSnapshots.removeAll()
        cacheOrder.removeAll()
    }

    private func removeCachedSnapshot(for url: URL) {
        let key = Self.cacheKey(for: url)
        cachedSnapshots.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
    }

    private static func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func mountedLocations() -> [StorageExplorerLocation] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return StorageExplorerLocation(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isInternal: values.volumeIsInternal ?? false
            )
        }
        .sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
