import AppKit
import ScoloCore
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Browses measured folders with native macOS table and path controls.
struct StorageExplorerView: View {
    @Bindable var model: StorageExplorerModel
    let isMeasurementBlocked: Bool
    @State private var previewURL: URL?
    @State private var previewNavigation = StoragePreviewNavigation()
    @State private var presentation = StorageExplorerPresentation.list
    @State private var sortOrder = [
        KeyPathComparator(\StorageExplorerItem.allocatedBytes, order: .reverse)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let currentURL = model.currentURL {
                header
                pathBar(currentURL)
            }

            content
                .operationResultAnimation(isRunning: model.isLoading)
        }
        .task { model.prepareLocations() }
        .onChange(of: presentation) { _, _ in model.finishMapSelection() }
        .onDisappear {
            model.finishMapSelection()
            previewNavigation.stop()
            previewURL = nil
        }
        .quickLookPreview($previewURL, in: sortedItems.map(\.url))
        .onChange(of: previewURL) { _, url in
            guard let url else {
                previewNavigation.stop()
                return
            }
            guard let index = sortedItems.firstIndex(where: { $0.url == url }) else { return }
            let item = sortedItems[index]
            if !model.selection.contains(item.id) {
                model.selection = [item.id]
            }
            previewNavigation.scrollToRow(index)
        }
        .onChange(of: model.selection) { _, selection in
            guard previewURL != nil else { return }
            if let current = sortedItems.first(where: { $0.url == previewURL }),
               selection.contains(current.id) { return }
            previewURL = sortedItems.first(where: { selection.contains($0.id) })?.url
        }
        .onChange(of: model.currentURL) { _, _ in previewURL = nil }
        // Space previews the selection, as it does in Finder.
        //
        // `onKeyPress(.space)` cannot do this and did not: `NSTableView` consumes
        // space in `keyDown` for type-select, so the key never reached SwiftUI. A
        // keyboard shortcut is installed as a key equivalent instead, which is
        // offered the event before the responder chain ever sees it. Disabled with
        // no selection, so the shortcut does not fire on nothing.
        .background(alignment: .topLeading) {
            Button("Quick Look") { previewSelection() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedItems.isEmpty)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func previewSelection() {
        guard let item = model.selectedItems.first else { return }
        showPreview(item)
    }

    private func showPreview(_ item: StorageExplorerItem) {
        previewNavigation.start { direction in
            let items = sortedItems
            guard let index = items.firstIndex(where: { $0.url == previewURL }) else { return }
            let next = index + direction
            guard items.indices.contains(next) else { return }
            model.selection = [items[next].id]
            previewURL = items[next].url
            previewNavigation.scrollToRow(next)
        }
        previewURL = item.url
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
        } else if presentation == .map {
            treemap
        } else {
            table
        }
    }

    /// What this folder holds, and the controls that act on the page.
    ///
    /// The path used to sit in the leading slot here and it could not: a path
    /// control does not compress, so it took the width the trailing controls needed
    /// and drew straight over them. It has a row of its own below.
    ///
    /// There is no selection readout and no Deselect All: the highlighted rows say
    /// what is picked, the Remove button says what it would take, and clicking away
    /// from the rows clears them, as it does in any table on this platform.
    private var header: some View {
        PageHeader {
            HStack(spacing: 8) {
                ForEach(StorageExplorerPresentation.allCases) { option in
                    PageTabPill(
                        title: option.rawValue,
                        symbol: option == .list ? "list.bullet" : "square.grid.2x2",
                        isSelected: presentation == option
                    ) { presentation = option }
                }
            }
        } trailing: {
            Button {
                model.refresh()
            } label: {
                Label("Measure Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PageActionButtonStyle())
            .fixedSize()
            .disabled(isMeasurementBlocked || model.isLoading)

            locationMenu
                .fixedSize()
        }
    }

    private var summaryText: String {
        guard let snapshot = model.snapshot else {
            return model.currentURL?.lastPathComponent.nonEmpty ?? "This Mac"
        }
        let count = snapshot.items.count
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) · \(ByteFormatting.string(snapshot.allocatedBytes))"
    }

    /// Where you are, and the two ways back — a row of its own, because both are
    /// navigation and neither survives being squeezed.
    ///
    /// The arrows used to be the window's toolbar pair. Those meant pages everywhere
    /// else and folders here — one control with two meanings — so they went, and
    /// this is the half that was doing real work: the path control beside them only
    /// ever walks *up*, and returning to a folder seen earlier has no other route.
    private func pathBar(_ url: URL) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack || isMeasurementBlocked)
                    .help("Back to the last folder")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward || isMeasurementBlocked)
                    .help("Forward")
            }
            .buttonStyle(.accessoryBar)
            .fixedSize()

            NativePathControl(url: url, onSelect: model.navigate)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .disabled(isMeasurementBlocked || model.isLoading)

            if model.snapshot != nil {
                Text(summaryText)
                    .pageHeaderSummary()
                    .monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }

    private var startView: some View {
        ContentUnavailableView {
            Label("Explore storage", systemImage: "internaldrive")
        } description: {
            Text("Choose a folder or volume. Scolo will measure each item on disk.")
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
        PageProgressView(
            title: "Measuring \(model.currentURL?.lastPathComponent.nonEmpty ?? "the selected folder")",
            detail: progressText,
            onStop: { model.cancel() }
        )
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
            HStack(spacing: 10) {
                Button("Try Again") { model.refresh() }
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                Button("Choose Another Folder") { model.chooseFolder() }
                    .buttonStyle(PageActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cancelledView: some View {
        ContentUnavailableView {
            Label("Measurement stopped", systemImage: "stop.circle")
        } description: {
            Text("Measure this folder again or choose another location.")
        } actions: {
            HStack(spacing: 10) {
                Button("Measure Again") { model.refresh() }
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                Button("Choose Another Folder") { model.chooseFolder() }
                    .buttonStyle(PageActionButtonStyle())
            }
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
        // A native `Table` paints its own backdrop, and that backdrop is the window
        // material — translucent, so it takes a wash of whatever wallpaper is behind
        // the window. This page stood visibly brown against the Scanner's opaque
        // #242125, and because the table scrolls under the toolbar, the toolbar
        // blurred the same material and went brown with it. Hidden, the page colour
        // behind shows through and the two views match.
        //
        // This is the same fault History had on 20 Sep. That one was rewritten away
        // from `Table` altogether, which also cost it column resizing; one modifier
        // would have done, and does here.
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: StorageExplorerItem.ID.self) { selection in
            if selection.count == 1, let item = firstItem(in: selection), item.opensAsDirectory {
                Button("Open") { model.open(item) }
                    .disabled(isMeasurementBlocked)
            }
            if selection.count == 1, let item = firstItem(in: selection) {
                Button("Quick Look") { showPreview(item) }
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
                showPreview(item)
            }
        }
    }

    private var treemap: some View {
        StorageTreemapView(
            items: model.snapshot?.items ?? [],
            selection: Binding(
                get: { model.selection },
                set: { model.selectMapItems($0) }
            ),
            isNavigationDisabled: isMeasurementBlocked,
            onOpen: { model.open($0) },
            onPreview: { showPreview($0) }
        )
    }

    private var sortedItems: [StorageExplorerItem] {
        (model.snapshot?.items ?? []).sorted(using: sortOrder)
    }

    private func nameCell(_ item: StorageExplorerItem) -> some View {
        HStack(spacing: 8) {
            StorageItemIcon(item: item, size: 18)

            Text(item.name)
                .lineLimit(1)

            if item.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("This item is hidden in Finder.")
            }

            if item.cloudState != .none {
                Image(systemName: cloudSymbol(item.cloudState))
                    .foregroundStyle(.secondary)
                    .help(cloudDescription(item.cloudState))
            }

            if item.kind == .symbolicLink {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .help("Scolo measures the link itself. Its target is not included.")
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
            HStack(spacing: 7) {
                Label("Choose Location", systemImage: "folder")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PageActionButtonStyle())
        .menuIndicator(.hidden)
        .disabled(isMeasurementBlocked || model.isLoading)
    }

    private func errorDescription(_ error: StorageExplorerError) -> String {
        switch error {
        case .unavailable:
            "Scolo cannot access this folder. Check its permissions and try again."
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
            "Scolo could not read all contents."
        case .system:
            "Scolo protects this system location."
        case .library:
            "Library folders belong to the Scanner. Use Scanner to remove caches, logs and app data."
        case .trash:
            "This is the Trash. Use the Trash view to empty it or put items back."
        case .application:
            "Use App Uninstaller to remove this application."
        case .mediaLibrary:
            "Photos, Music or TV manages this library. Remove items in that app."
        case .volume:
            "Scolo measures this volume separately. Use macOS tools to eject or erase it."
        case .cloudOnly:
            "This item contains iCloud files that are not on this Mac. Scolo protects them from removal."
        case .unavailable:
            "Scolo cannot verify this item."
        }
    }

    private func cloudDescription(_ state: StorageExplorerItem.CloudState) -> String {
        switch state {
        case .none:
            ""
        case .downloaded:
            "This item is stored on this Mac and in iCloud. Moving it to the Trash removes it from other devices."
        case .cloudOnly:
            "This iCloud item is not stored on this Mac."
        case .containsCloudOnlyItems:
            "This item contains iCloud files that are not stored on this Mac."
        }
    }

    private func cloudSymbol(_ state: StorageExplorerItem.CloudState) -> String {
        switch state {
        case .none, .downloaded:
            "icloud"
        case .cloudOnly, .containsCloudOnlyItems:
            "icloud.and.arrow.down"
        }
    }
}

private enum StorageExplorerPresentation: String, CaseIterable, Identifiable {
    case list = "List"
    case map = "Map"

    var id: Self { self }
}

/// Gives known file types the same icon in the list and map.
private struct StorageItemIcon: View {
    let item: StorageExplorerItem
    let size: CGFloat

    var body: some View {
        Group {
            if let appearance {
                Image(systemName: appearance.symbol)
                    .font(.system(size: size >= 32 ? size * 0.62 : size * 0.9, weight: .regular))
                    .foregroundStyle(appearance.color)
                    .frame(width: size, height: size)
                    .background {
                        if size >= 32 {
                            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                                .fill(appearance.color.opacity(0.10))
                        }
                    }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private var appearance: (symbol: String, color: Color)? {
        guard item.kind == .file || item.kind == .package else { return nil }
        let ext = item.url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            || ["mkv", "webm", "avi", "imovielibrary", "fcpbundle"].contains(ext) {
            return ("play.rectangle.fill", Token.textColor(.pink))
        }
        if type?.conforms(to: .image) == true || ["photoslibrary", "photolibrary", "raw"].contains(ext) {
            return ("photo.fill", Token.textColor(.orange))
        }
        if type?.conforms(to: .audio) == true || ["flac", "ogg", "opus"].contains(ext) {
            return ("waveform", Token.textColor(.pink))
        }
        if type?.conforms(to: .pdf) == true {
            return ("doc.richtext.fill", Token.textColor(.red))
        }
        if type?.conforms(to: .sourceCode) == true
            || ["js", "jsx", "ts", "tsx", "py", "rs", "go", "css", "json", "yaml", "yml"].contains(ext) {
            return ("chevron.left.forwardslash.chevron.right", Token.textColor(.purple))
        }
        if type?.conforms(to: .spreadsheet) == true || ["csv", "numbers", "xlsx", "xls"].contains(ext) {
            return ("tablecells.fill", Token.textColor(.green))
        }
        if type?.conforms(to: .presentation) == true || ["key", "pptx", "ppt"].contains(ext) {
            return ("rectangle.on.rectangle", Token.textColor(.orange))
        }
        if type?.conforms(to: .text) == true || ["pages", "doc", "docx", "odt"].contains(ext) {
            return ("doc.text.fill", Token.textColor(.accent))
        }
        if type?.conforms(to: .archive) == true || ["7z", "rar", "gz", "bz2", "xz"].contains(ext) {
            return ("doc.zipper", Token.textColor(.orange))
        }
        if type?.conforms(to: .diskImage) == true || ["dmg", "iso", "sparsebundle"].contains(ext) {
            return ("externaldrive.fill", Token.Text.secondary)
        }
        if ext == "pkg" {
            return ("shippingbox.fill", Token.textColor(.orange))
        }
        return nil
    }
}

/// Shows the current Storage Explorer level as proportional tiles.
private struct StorageTreemapView: View {
    let items: [StorageExplorerItem]
    @Binding var selection: Set<StorageExplorerItem.ID>
    let isNavigationDisabled: Bool
    let onOpen: (StorageExplorerItem) -> Void
    let onPreview: (StorageExplorerItem) -> Void

    @State private var hoveredID: StorageExplorerItem.ID?
    @State private var hoverPoint: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileGap: CGFloat = 8
    private var outerPadding: CGFloat { Token.Size.pageGutter - tileGap / 2 }

    @ViewBuilder
    var body: some View {
        if items.contains(where: { $0.allocatedBytes > 0 }) {
            GeometryReader { proxy in
                let cells = StorageTreemapLayout.cells(for: items.map {
                    .init(id: $0.id, bytes: $0.allocatedBytes)
                })
                let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

                ZStack(alignment: .topLeading) {
                    Token.pageBackground

                    ForEach(cells) { cell in
                        if let item = itemsByID[cell.id] {
                            let frame = tileFrame(cell, in: proxy.size)
                            tile(item, frame: frame)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .coordinateSpace(name: "StorageExplorerTreemap")
                .overlay(alignment: .topLeading) {
                    tooltip(itemsByID: itemsByID)
                }
                .overlay(alignment: .bottomLeading) {
                    zeroSizeNote
                }
            }
        } else {
            ContentUnavailableView {
                Label("No allocated space to map", systemImage: "square.grid.3x3")
            } description: {
                Text("Switch to List to see items that use 0 B.")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func tile(_ item: StorageExplorerItem, frame: CGRect) -> some View {
        let gap = min(tileGap, min(frame.width, frame.height) * 0.12)
        let size = CGSize(width: max(0, frame.width - gap), height: max(0, frame.height - gap))
        let isSelected = selection.contains(item.id)
        let isHovered = hoveredID == item.id
        let isFullCard = size.width >= 150 && size.height >= 138
        let shape = RoundedRectangle(
            cornerRadius: min(Token.Radius.card, min(size.width, size.height) / 4),
            style: .continuous
        )

        return Button {
            select(item)
        } label: {
            ZStack {
                shape.fill(isSelected ? Token.color(.accent).opacity(0.10) : Token.Fill.box)
                if isHovered {
                    shape.fill(Token.Fill.controlHover.opacity(0.5))
                }
                if size.width >= 54, size.height >= 30 {
                    tileLabel(item, size: size)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(CardPressButtonStyle(
            cornerRadius: min(Token.Radius.card, min(size.width, size.height) / 4)
        ))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { activate(item) }
        )
        .overlay {
            shape.strokeBorder(
                isSelected ? Token.color(.accent) : Token.Fill.boxBorder,
                lineWidth: isSelected ? 1.5 : Token.hairline
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if isFullCard {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Token.color(.accent) : Token.Text.disabled)
                    if !item.isRemovable {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                    }
                    if item.cloudState != .none {
                        Image(systemName: cloudSymbol(item.cloudState))
                            .font(.system(size: 11))
                    }
                }
                .foregroundStyle(Token.Text.tertiary)
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFullCard {
                Button { activate(item) } label: {
                    Image(systemName: item.opensAsDirectory ? "chevron.right" : "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Token.Text.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.opensAsDirectory && isNavigationDisabled)
                .padding(5)
                .help(item.opensAsDirectory ? "Open this folder" : "Preview this file")
                .accessibilityLabel("\(item.opensAsDirectory ? "Open" : "Preview") \(item.name)")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .padding(gap / 2)
        .onContinuousHover(coordinateSpace: .named("StorageExplorerTreemap")) { phase in
            switch phase {
            case let .active(location):
                hoveredID = item.id
                hoverPoint = needsTooltip(item, size: size) ? location : nil
            case .ended:
                if hoveredID == item.id {
                    hoveredID = nil
                    hoverPoint = nil
                }
            }
        }
        .onChange(of: size) { _, updatedSize in
            if hoveredID == item.id, !needsTooltip(item, size: updatedSize) {
                hoverPoint = nil
            }
        }
        .contextMenu {
            if item.opensAsDirectory {
                Button("Open") { open(item) }
                    .disabled(isNavigationDisabled)
            }
            Button("Quick Look") { onPreview(item) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue(item))
        .accessibilityHint(
            item.opensAsDirectory
                ? "Double-click to open this folder."
                : "Double-click to preview this file."
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: item.opensAsDirectory ? "Open" : "Quick Look") {
            activate(item)
        }
    }

    @ViewBuilder
    private func tileLabel(_ item: StorageExplorerItem, size: CGSize) -> some View {
        if size.width >= 110, size.height >= 110 {
            let iconSize: CGFloat = size.width >= 150 && size.height >= 138 ? 48 : 32
            VStack(spacing: 6) {
                StorageItemIcon(item: item, size: iconSize)
                    .padding(.bottom, 2)
                Text(item.name)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(ByteFormatting.string(item.allocatedBytes))
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, size.height >= 138 ? 12 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if size.width >= 100 {
                        StorageItemIcon(item: item, size: 18)
                    }
                    Text(item.name)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if size.height >= 58 {
                    Text(ByteFormatting.string(item.allocatedBytes))
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Match the label width, font, and line count before showing extra information.
    private func needsTooltip(_ item: StorageExplorerItem, size: CGSize) -> Bool {
        guard size.width >= 54, size.height >= 58 else { return true }
        let isCentered = size.width >= 110 && size.height >= 110
        let width = max(0, size.width - (isCentered ? 24 : 16))
        let nameWidth = max(0, width - (!isCentered && size.width >= 100 ? 23 : 0))
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let name = item.name as NSString
        let value = ByteFormatting.string(item.allocatedBytes) as NSString
        if value.size(withAttributes: [.font: valueFont]).width > width { return true }
        if !isCentered {
            return name.size(withAttributes: [.font: nameFont]).width > nameWidth
        }
        let nameBounds = name.boundingRect(
            with: CGSize(width: nameWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: nameFont]
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: nameFont)
        return ceil(nameBounds.height) > ceil(lineHeight * 2)
    }

    @ViewBuilder
    private func tooltip(
        itemsByID: [String: StorageExplorerItem]
    ) -> some View {
        if let hoveredID,
           let item = itemsByID[hoveredID],
           let hoverPoint {
            TreemapTooltipLayout(anchor: hoverPoint) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text(treemapDetail(item))
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
                }
                .shadow(color: Token.chipShadow, radius: 8, y: 2)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var zeroSizeNote: some View {
        let count = items.filter { $0.allocatedBytes <= 0 }.count
        if count > 0 {
            let noun = count == 1 ? "item" : "items"
            let verb = count == 1 ? "is" : "are"
            Text("\(count) \(noun) using 0 B \(verb) not shown.")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Token.Fill.box, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
                }
                .padding(Token.Size.pageGutter)
        }
    }

    private func tileFrame(
        _ cell: StorageTreemapLayout.Cell,
        in size: CGSize
    ) -> CGRect {
        let width = max(0, size.width - outerPadding * 2)
        let height = max(0, size.height - outerPadding * 2)
        return CGRect(
            x: outerPadding + width * cell.x,
            y: outerPadding + height * cell.y,
            width: width * cell.width,
            height: height * cell.height
        )
    }

    private func select(_ item: StorageExplorerItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) }
            else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    private func activate(_ item: StorageExplorerItem) {
        if item.opensAsDirectory { open(item) }
        else { onPreview(item) }
    }

    private func open(_ item: StorageExplorerItem) {
        guard !isNavigationDisabled else { return }
        onOpen(item)
    }

    private func cloudSymbol(_ state: StorageExplorerItem.CloudState) -> String {
        switch state {
        case .none, .downloaded:
            "icloud"
        case .cloudOnly, .containsCloudOnlyItems:
            "icloud.and.arrow.down"
        }
    }

    private func treemapDetail(_ item: StorageExplorerItem) -> String {
        let protection = item.protectionReason.map { " · " + protectionTitle($0) } ?? ""
        return "\(ByteFormatting.string(item.allocatedBytes)) · \(item.kindTitle)" + protection
    }

    private func protectionTitle(
        _ reason: StorageExplorerItem.ProtectionReason
    ) -> String {
        switch reason {
        case .excluded:           "Excluded"
        case .protectedContents:  "Contains protected data"
        case .unreadableContents: "Unreadable contents"
        case .system:             "System location"
        case .library:            "Use Scanner"
        case .trash:              "Use Trash"
        case .application:        "Use App Uninstaller"
        case .mediaLibrary:       "Managed media library"
        case .volume:             "Mounted volume"
        case .cloudOnly:          "Cloud-only contents"
        case .unavailable:        "Unavailable"
        }
    }

    private func accessibilityValue(_ item: StorageExplorerItem) -> String {
        let protection = item.isRemovable ? "" : ", protected"
        return "\(ByteFormatting.string(item.allocatedBytes)), \(item.kindTitle)" + protection
    }
}

private struct TreemapTooltipLayout: Layout {
    let anchor: CGPoint

    private let margin: CGFloat = 8
    private let spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(.unspecified)
        let anchorInBounds = CGPoint(
            x: bounds.minX + anchor.x,
            y: bounds.minY + anchor.y
        )
        let minimumX = bounds.minX + margin
        let maximumX = max(minimumX, bounds.maxX - size.width - margin)
        let right = anchorInBounds.x + spacing
        let left = anchorInBounds.x - size.width - spacing
        let x = right <= maximumX ? right : max(left, minimumX)

        let minimumY = bounds.minY + margin
        let maximumY = max(minimumY, bounds.maxY - size.height - margin)
        let below = anchorInBounds.y + spacing
        let above = anchorInBounds.y - size.height - spacing
        let y = below <= maximumY ? below : max(above, minimumY)

        tooltip.place(
            at: CGPoint(x: x, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}

extension StorageExplorerItem {
    var kindTitle: String {
        switch kind {
        case .file:         "File"
        case .folder:       "Folder"
        // A symbolic link, which Finder shows as one; an alias is a different thing.
        case .symbolicLink: "Symbolic link"
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

/// Keeps Quick Look navigation aligned with the displayed table order.
@MainActor
private final class StoragePreviewNavigation {
    private var keyMonitor: Any?
    private weak var sourceTable: NSTableView?

    func start(onMove: @escaping @MainActor (Int) -> Void) {
        if let table = NSApp.keyWindow?.firstResponder as? NSTableView {
            sourceTable = table
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard event.window is QLPreviewPanel,
                      !(event.window?.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return false }
                switch event.keyCode {
                case 125: onMove(1)
                case 126: onMove(-1)
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func scrollToRow(_ index: Int) {
        guard let sourceTable, index >= 0, index < sourceTable.numberOfRows else { return }
        sourceTable.scrollRowToVisible(index)
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        sourceTable = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
