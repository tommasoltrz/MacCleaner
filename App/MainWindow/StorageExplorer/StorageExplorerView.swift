import AppKit
import MacCleanerCore
import QuickLook
import SwiftUI

/// Browses measured folders with native macOS table and path controls.
struct StorageExplorerView: View {
    @Bindable var model: StorageExplorerModel
    let isMeasurementBlocked: Bool
    @State private var previewURL: URL?
    @State private var sortOrder = [
        KeyPathComparator(\StorageExplorerItem.allocatedBytes, order: .reverse)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let currentURL = model.currentURL {
                browserBar(currentURL)
                Divider()
            }

            content
        }
        .task { model.prepareLocations() }
        .quickLookPreview($previewURL)
        .onKeyPress(.space) {
            guard let item = model.selectedItems.first else { return .ignored }
            previewURL = item.url
            return .handled
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.currentURL == nil {
            startView
        } else if model.isLoading {
            loadingView
        } else if model.wasCancelled {
            cancelledView
        } else if let error = model.error {
            errorView(error)
        } else if model.snapshot?.items.isEmpty == true {
            emptyView
        } else {
            table
        }
    }

    private func browserBar(_ url: URL) -> some View {
        HStack(spacing: 10) {
            NativePathControl(url: url, onSelect: model.navigate)
                .frame(minWidth: 260, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .disabled(isMeasurementBlocked || model.isLoading)

            Button {
                model.refresh()
            } label: {
                Label("Measure Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isMeasurementBlocked || model.isLoading)

            locationMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var startView: some View {
        ContentUnavailableView {
            Label("Explore storage", systemImage: "internaldrive")
        } description: {
            Text("Choose a folder or volume. MacCleaner will measure each item on disk.")
        } actions: {
            locationMenu
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Measuring \(model.currentURL?.lastPathComponent.nonEmpty ?? "the selected folder")")
                .font(.headline)
            Text(progressText)
                .foregroundStyle(.secondary)
            Button("Stop") { model.cancel() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressText: String {
        guard model.progress.fileCount > 0 else { return "Reading folder contents…" }
        return "Measured \(ByteFormatting.string(model.progress.allocatedBytes)) in "
            + "\(model.progress.fileCount.formatted()) files."
    }

    private func errorView(_ error: StorageExplorerError) -> some View {
        ContentUnavailableView {
            Label("The folder could not be read", systemImage: "folder.badge.questionmark")
        } description: {
            Text(errorDescription(error))
        } actions: {
            Button("Try Again") { model.refresh() }
                .buttonStyle(.borderedProminent)
            Button("Choose Another Folder") { model.chooseFolder() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cancelledView: some View {
        ContentUnavailableView {
            Label("Measurement stopped", systemImage: "stop.circle")
        } description: {
            Text("Measure this folder again or choose another location.")
        } actions: {
            Button("Measure Again") { model.refresh() }
                .buttonStyle(.borderedProminent)
            Button("Choose Another Folder") { model.chooseFolder() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("This folder is empty", systemImage: "folder")
        } description: {
            Text("Choose another folder or return to the previous folder.")
        } actions: {
            locationMenu
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var table: some View {
        Table(sortedItems, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn(
                "Name",
                sortUsing: KeyPathComparator(\StorageExplorerItem.name)
            ) { item in
                nameCell(item)
            }
            .width(min: 260, ideal: 420)

            TableColumn(
                "Kind",
                sortUsing: KeyPathComparator(\StorageExplorerItem.kindSortName)
            ) { item in
                Text(item.kindTitle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120, max: 160)

            TableColumn(
                "Files",
                sortUsing: KeyPathComparator(\StorageExplorerItem.fileCount)
            ) { item in
                Text(item.fileCountLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 78, max: 96)

            TableColumn(
                "Modified",
                sortUsing: KeyPathComparator(\StorageExplorerItem.modificationSortValue)
            ) { item in
                Text(item.modificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 98, ideal: 120, max: 150)

            TableColumn(
                "Size",
                sortUsing: KeyPathComparator(\StorageExplorerItem.allocatedBytes)
            ) { item in
                Text(ByteFormatting.string(item.allocatedBytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 86, ideal: 104, max: 124)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: StorageExplorerItem.ID.self) { selection in
            if selection.count == 1, let item = firstItem(in: selection), item.opensAsDirectory {
                Button("Open") { model.open(item) }
                    .disabled(isMeasurementBlocked)
            }
            if selection.count == 1, let item = firstItem(in: selection) {
                Button("Quick Look") { previewURL = item.url }
            }
            if !selection.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls(in: selection))
                }
            }
        } primaryAction: { selection in
            guard selection.count == 1, let item = firstItem(in: selection) else { return }
            if item.opensAsDirectory {
                if !isMeasurementBlocked { model.open(item) }
            } else {
                previewURL = item.url
            }
        }
    }

    private var sortedItems: [StorageExplorerItem] {
        (model.snapshot?.items ?? []).sorted(using: sortOrder)
    }

    private func nameCell(_ item: StorageExplorerItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)

            Text(item.name)
                .lineLimit(1)

            if item.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("This item is hidden in Finder.")
            }

            if let reason = item.protectionReason {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(protectionDescription(reason))
            }
        }
    }

    private func firstItem(in selection: Set<StorageExplorerItem.ID>) -> StorageExplorerItem? {
        model.snapshot?.items.first { selection.contains($0.id) }
    }

    private func urls(in selection: Set<StorageExplorerItem.ID>) -> [URL] {
        model.snapshot?.items.compactMap { selection.contains($0.id) ? $0.url : nil } ?? []
    }

    private var locationMenu: some View {
        Menu {
            Button {
                model.selectHome()
            } label: {
                Label("Home Folder", systemImage: "house")
            }

            if !model.locations.isEmpty { Divider() }
            ForEach(model.locations) { location in
                Button {
                    model.selectLocation(location.url)
                } label: {
                    Label(location.name, systemImage: location.symbol)
                }
            }

            Divider()
            Button {
                model.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Choose Location", systemImage: "folder")
        }
        .menuStyle(.button)
        .disabled(isMeasurementBlocked || model.isLoading)
    }

    private func errorDescription(_ error: StorageExplorerError) -> String {
        switch error {
        case .unavailable:
            "MacCleaner cannot access this folder. Check its permissions and try again."
        case .notDirectory:
            "Choose a folder or mounted volume."
        }
    }

    private func protectionDescription(
        _ reason: StorageExplorerItem.ProtectionReason
    ) -> String {
        switch reason {
        case .excluded:
            "This item contains an excluded path."
        case .protectedContents:
            "This item contains protected data."
        case .unreadableContents:
            "MacCleaner could not read all contents."
        case .system:
            "MacCleaner protects this system location."
        case .application:
            "Use App Uninstaller to remove this application."
        case .package:
            "Storage Explorer protects this package."
        case .volume:
            "Use macOS tools to eject or erase this volume."
        case .unavailable:
            "MacCleaner cannot verify this item."
        }
    }
}

private extension StorageExplorerItem {
    var kindTitle: String {
        switch kind {
        case .file:         "File"
        case .folder:       "Folder"
        case .symbolicLink: "Alias"
        case .package:      "Package"
        case .application:  "Application"
        case .volume:       "Volume"
        }
    }

    var kindSortName: String { kindTitle }
    var fileCountLabel: String {
        switch kind {
        case .file, .symbolicLink:
            "—"
        case .folder, .package, .application, .volume:
            fileCount.formatted()
        }
    }
    var modificationSortValue: TimeInterval {
        modificationDate?.timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
