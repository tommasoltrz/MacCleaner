import AppKit
import ScoloCore
import QuickLook
import SwiftUI

/// Browses measured folders with native macOS table and path controls.
struct StorageExplorerView: View {
    @Bindable var model: StorageExplorerModel
    let isMeasurementBlocked: Bool
    @State private var previewURL: URL?
    @State private var presentation = StorageExplorerPresentation.list
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
        } else if presentation == .map {
            treemap
        } else {
            table
        }
    }

    private func browserBar(_ url: URL) -> some View {
        HStack(spacing: 10) {
            NativePathControl(url: url, onSelect: model.navigate)
                .frame(minWidth: 260, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .disabled(isMeasurementBlocked || model.isLoading)

            Picker("Presentation", selection: $presentation) {
                ForEach(StorageExplorerPresentation.allCases) { presentation in
                    Text(presentation.rawValue).tag(presentation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 124)

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
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var treemap: some View {
        StorageTreemapView(
            items: model.snapshot?.items ?? [],
            selection: Binding(
                get: { model.selection },
                set: { model.selection = $0 }
            ),
            isNavigationDisabled: isMeasurementBlocked,
            onOpen: { model.open($0) },
            onPreview: { previewURL = $0.url }
        )
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
            Label("Choose Location", systemImage: "folder")
        }
        .menuStyle(.button)
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

/// Shows the current Storage Explorer level as proportional tiles.
private struct StorageTreemapView: View {
    let items: [StorageExplorerItem]
    @Binding var selection: Set<StorageExplorerItem.ID>
    let isNavigationDisabled: Bool
    let onOpen: (StorageExplorerItem) -> Void
    let onPreview: (StorageExplorerItem) -> Void

    @State private var hoveredID: StorageExplorerItem.ID?
    @State private var hoverPoint: CGPoint?

    private let outerPadding: CGFloat = 10
    private let tileGap: CGFloat = 2
    private let palette: [NSColor] = [
        .systemBlue,
        .systemTeal,
        .systemIndigo,
        .systemOrange,
        .systemPurple,
        .systemGreen,
        .systemPink,
        .systemRed,
        .systemYellow,
    ]

    @ViewBuilder
    var body: some View {
        if items.contains(where: { $0.allocatedBytes > 0 }) {
            GeometryReader { proxy in
                let cells = StorageTreemapLayout.cells(for: items.map {
                    .init(id: $0.id, bytes: $0.allocatedBytes)
                })
                let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

                ZStack(alignment: .topLeading) {
                    Token.Fill.well

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
        let size = frame.size
        let isSelected = selection.contains(item.id)
        let isHovered = hoveredID == item.id
        let shape = RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous)

        return Button {
            select(item)
        } label: {
            ZStack(alignment: .topLeading) {
                shape.fill(.regularMaterial)
                shape.fill(tileColor(item).opacity(tileOpacity(item, hovered: isHovered)))

                if size.width >= 54, size.height >= 30 {
                    tileLabel(item, size: size)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(
            shape.strokeBorder(
                isSelected ? Color.accentColor : Token.Fill.boxBorder,
                lineWidth: isSelected ? 2 : Token.hairline
            )
        )
        .padding(tileGap / 2)
        .onContinuousHover(coordinateSpace: .named("StorageExplorerTreemap")) { phase in
            switch phase {
            case let .active(location):
                hoveredID = item.id
                hoverPoint = location
            case .ended:
                if hoveredID == item.id {
                    hoveredID = nil
                    hoverPoint = nil
                }
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { activate(item) }
        )
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if size.width >= 82 {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }
                Text(item.name)
                    .font(.mcRowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if item.cloudState != .none, size.width >= 112 {
                    Image(systemName: cloudSymbol(item.cloudState))
                        .foregroundStyle(Token.Text.secondary)
                }
                if !item.isRemovable, size.width >= 92 {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Token.Text.secondary)
                }
            }

            if size.height >= 58 {
                Text(ByteFormatting.string(item.allocatedBytes))
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
                    .monospacedDigit()
            }

            if size.width >= 120, size.height >= 82 {
                Text(item.kindTitle)
                    .font(.mcBadge)
                    .foregroundStyle(Token.Text.tertiary)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func tooltip(
        itemsByID: [String: StorageExplorerItem]
    ) -> some View {
        if let hoveredID,
           let item = itemsByID[hoveredID],
           let hoverPoint {
            TreemapTooltipLayout(anchor: hoverPoint) {
                HoverTip(
                    primary: tooltipName(item.name),
                    secondary: treemapDetail(item)
                )
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
                .background(.regularMaterial, in: Capsule())
                .padding(12)
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

    private func tileColor(_ item: StorageExplorerItem) -> Color {
        Color(nsColor: palette[stablePaletteIndex(for: item.id)])
    }

    private func stablePaletteIndex(for path: String) -> Int {
        // FNV-1a keeps each path mapped to the same color across launches.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(palette.count))
    }

    private func tileOpacity(_ item: StorageExplorerItem, hovered: Bool) -> Double {
        if !item.isRemovable { return hovered ? 0.20 : 0.13 }
        return hovered ? 0.34 : 0.24
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

    private func tooltipName(_ name: String) -> String {
        let maximumLength = 48
        guard name.count > maximumLength else { return name }
        return String(name.prefix(maximumLength - 1)) + "…"
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
