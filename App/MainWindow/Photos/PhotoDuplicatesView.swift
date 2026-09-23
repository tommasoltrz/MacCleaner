import AppKit
import SwiftUI
import ScoloCore

/// The duplicate review grid.
///
/// The grid is the feature, not a nicety. Bulk-deleting photographs on the strength
/// of a similarity score is only defensible if the user can see what is going and
/// what is being kept, side by side, before anything happens — so every group shows
/// its keeper next to its casualties at the same size, and the keeper is not
/// selectable from here at all.
struct PhotoDuplicatesView: View {
    @Bindable var model: AppModel
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    private var thumbnails: PhotoThumbnailLoader { model.photoDuplicates.thumbnails }

    var body: some View {
        Group {
            if model.photoDuplicates.isScanning {
                sweeping
            } else if let reason = model.photoDuplicates.unavailableReason {
                unavailable(reason)
            } else if model.photoDuplicates.results == nil {
                intro
            } else if model.photoDuplicates.groups.isEmpty {
                nothingFound
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.photoDuplicates.isDeleting)
        .operationResultAnimation(isRunning: model.photoDuplicates.isScanning)
        .onChange(of: model.photoDuplicates.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.photoDuplicates.results?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.photoDuplicates.results?.finishedAt != nil
                    && model.photoDuplicates.results?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.photoDuplicates.similarity) { _, _ in animateEmptyResult = false }
        .onDisappear { animateEmptyResult = false }
    }

    // MARK: - States

    private var intro: some View {
        // The same system empty state the Scanner uses, so the app has one idle
        // screen rather than separate hand-drawn variations.
        ContentUnavailableView {
            Label("Find duplicate photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Compares every photo in your iCloud library by appearance, not by "
                 + "filename or date. Photos missing a local thumbnail are fetched "
                 + "from iCloud at preview size — originals are never downloaded.")
        } actions: {
            Button("Find Duplicates") { model.startPhotoSweep() }
                .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                .controlSize(.large)
                .scanActionAnchor()
                // The sweep refuses to start over another disk walk; say so here
                // rather than swallowing the click.
                .disabled(model.isBusyWithDisk)
        }
        .pageStateLayout()
    }

    private var sweeping: some View {
        ScanProgressPage {
            intro
        } progress: { actionBottom in
            PageProgressView(
                title: "Scanning for duplicate photos",
                detail: "\(progressLabel)\nThis may take a few minutes.",
                progress: Double(model.photoDuplicates.progress?.percent ?? 0) / 100,
                onStop: { model.photoDuplicates.cancelScan() },
                actionBottom: actionBottom
            )
        }
    }

    private var progressLabel: String {
        guard let progress = model.photoDuplicates.progress else { return "Preparing…" }
        return switch progress.stage {
        case .fetching:      "Reading your photo library…"
        case .grouping:
            progress.percent > 90
                ? "Comparing \(progress.total.formatted()) photos to each other…"
                : "Grouping bursts…"
        case .fingerprinting:
            "Comparing photos — \(progress.completed.formatted()) of \(progress.total.formatted())"
        case .done:          "Finishing…"
        }
    }

    private func unavailable(_ reason: String) -> some View {
        centred {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Token.textColor(.orange))
            Text(reason)
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again") { model.startPhotoSweep() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusyWithDisk)
        }
    }

    private var nothingFound: some View {
        ScanCompletionView(
            title: "No duplicate photos found",
            detail: model.photoDuplicates.results.map { summary($0) },
            animate: animateEmptyResult
        )
    }

    /// A skipped photo was never compared, so the result is a floor rather than a
    /// total. Saying so is the same rule the scanners follow with `unreadableCount`.
    private func summary(_ results: PhotoDuplicateResults) -> String {
        var text = "Compared \(results.examinedCount.formatted()) photos."
        if results.skippedCount > 0 {
            text += " \(results.skippedCount.formatted()) had no thumbnail available "
                + "and were not compared."
        }
        return text
    }

    private var groups: some View {
        let selectable = Set(model.photoDuplicates.groups.flatMap(\.removable).map(\.id))
        return VStack(spacing: 0) {
            HStack {
                MonochromeCheckbox(
                    title: "Select All",
                    detail: "\(selectable.count) items",
                    state: !selectable.isEmpty && selectable.isSubset(of: model.photoDuplicates.selection) ? .on : .off,
                    isEnabled: !selectable.isEmpty && !model.isBusyWithDisk && !model.photoDuplicates.isRegrouping
                ) { isOn in
                    if isOn { model.photoDuplicates.selectAll() }
                    else { model.photoDuplicates.deselectAll() }
                }
                .fixedSize()
                Spacer()
                if let results = model.photoDuplicates.results, results.skippedCount > 0 {
                    Text(summary(results)).pageHeaderSummary()
                }
            }
            .padding(.horizontal, Token.Size.pageGutter + 15)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.photoDuplicates.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, Token.Size.pageGutter)
                .padding(.vertical, 14)
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Badge(text: kindLabel(group.kind), style: group.kind == .similar ? .neutral : .safe)
                        // The badge names how the group was decided, not how sure
                        // Scolo is — a "Looks similar" group at 0.03 is the same
                        // photograph twice, and reads as a guess without this.
                        .help(badgeExplanation(group.kind))
                    // The number the threshold was compared against, on the groups
                    // a number decided. Without it "Looks similar" is the same
                    // sentence whether the match was tight or barely made, and the
                    // similarity setting is a dial with no readout.
                    if let distance = group.maximumDistance {
                        Text(String(format: "%.2f", distance))
                            .font(.mcCaption.monospacedDigit())
                            .foregroundStyle(Token.Text.tertiary)
                            .help("How far apart the two least alike photographs here are. "
                                  + "Lower is more alike; zero is the same image. "
                                  + "This group was formed at \(model.photoDuplicates.similarity.thresholdLabel) "
                                  + "or closer.")
                    }
                    Text("\(group.count) copies · keeping 1")
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text("(\(group.keeperReason.label))")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                    if let date = group.keeper.creationDate {
                        Text(date, format: .dateTime.day().month().year())
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.Text.tertiary)
                    }
                    Spacer()
                    Button(allSelected(group) ? "Deselect" : "Select \(group.removable.count)") {
                        toggleGroup(group)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(group.assets) { asset in
                            tile(asset, in: group)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(12)
        }
    }

    private func badgeExplanation(_ kind: DuplicateGroup.Kind) -> String {
        switch kind {
        case .burst:
            "Photos itself recorded these as one burst."
        case .exact:
            "Same capture time, size and kind, and the pictures agree. "
                + "Scolo is as sure of this as it gets."
        case .similar:
            "Grouped because the pictures look alike, at the setting in the header — "
                + "the number beside this says how alike. A tight one is often the same "
                + "photograph re-saved, which misses Identical only because its capture "
                + "time or size changed. Choose Identical only to be shown none of these."
        }
    }

    private func kindLabel(_ kind: DuplicateGroup.Kind) -> String {
        switch kind {
        case .burst:   "Burst"
        case .exact:   "Identical"
        // Named for what it is. The certain tiers are visually confirmed matches;
        // this one is a judgement call, and the badge should not imply otherwise.
        case .similar: "Looks similar"
        }
    }

    private func tile(_ asset: PhotoAsset, in group: DuplicateGroup) -> some View {
        let isKeeper = asset.id == group.keeper.id
        let selected = model.photoDuplicates.selection.contains(asset.id)

        return VStack(spacing: 5) {
            thumbnail(asset)
                .overlay {
                    RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous)
                        .strokeBorder(
                            isKeeper ? Token.color(.green).opacity(0.7)
                                : (selected ? Token.color(.red) : Token.Fill.boxBorder),
                            lineWidth: isKeeper || selected ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
            Text(isKeeper ? "Keep" : (selected ? "Delete" : "Keeping"))
                .font(.mcBadge)
                .foregroundStyle(
                    isKeeper ? Token.textColor(.green)
                        : (selected ? Token.textColor(.red) : Token.Text.tertiary)
                )
        }
        .contentShape(Rectangle())
        .overlay {
            PhotoThumbnailClickTarget(
                isSelected: Binding(
                    get: { model.photoDuplicates.selection.contains(asset.id) },
                    set: { isSelected in
                        guard !isKeeper else { return }
                        model.photoDuplicates.setSelected(isSelected, assetID: asset.id)
                    }
                ),
                isSelectable: !isKeeper,
                onPreview: { model.photoDuplicates.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset) }
            )
        }
        .help(isKeeper ? "Double-click to preview" : "Click to select. Double-click to preview.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isKeeper ? "Photo to keep" : "Photo")
        .accessibilityValue(selected ? "Selected for deletion" : "Not selected for deletion")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if !isKeeper { model.photoDuplicates.toggle(asset.id) }
        }
        .accessibilityAction(named: Text("Preview photo")) {
            model.photoDuplicates.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset)
        }
        .overlay(alignment: .top) {
            if !isKeeper {
                HStack(spacing: 4) {
                    Button {
                        model.photoDuplicates.keepInstead(groupID: group.id, assetID: asset.id)
                    } label: {
                        Text("Keep")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep this photo instead")
                    .help("Choose this photo as the copy to keep")
                    Spacer(minLength: 0)
                    Button {
                        model.photoDuplicates.toggle(asset.id)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                selected ? Color.white : Color.white.opacity(0.9),
                                selected ? Token.color(.red) : Color.black.opacity(0.35)
                            )
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Deselect photo" : "Select photo for deletion")
                    .help(selected ? "Deselect photo" : "Select photo for deletion")
                }
                .padding(5)
            }
        }
        .contextMenu {
            if !isKeeper {
                Button("Keep This One Instead") {
                    model.photoDuplicates.keepInstead(groupID: group.id, assetID: asset.id)
                }
            }
            Button("Open") { model.photoDuplicates.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset) }
        }
    }

    private func thumbnail(_ asset: PhotoAsset) -> some View {
        Group {
            if let image = thumbnails.image(for: asset.id) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Token.Fill.well
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous))
        .task { thumbnails.load(asset.id) }
    }

    private func allSelected(_ group: DuplicateGroup) -> Bool {
        model.photoDuplicates.isGroupSelected(group.id)
    }

    private func toggleGroup(_ group: DuplicateGroup) {
        model.photoDuplicates.toggleGroup(group.id)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 18) { content() }
            .operationPageLayout()
    }
}

/// Selects immediately and restores the prior selection when a double-click opens the preview.
private struct PhotoThumbnailClickTarget: NSViewRepresentable {
    @Binding var isSelected: Bool
    let isSelectable: Bool
    let onPreview: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.allowsSelection = isSelectable
        nsView.selection = $isSelected
        nsView.onPreview = onPreview
    }

    final class ClickView: NSView {
        var isEnabled = true
        var allowsSelection = true
        var selection: Binding<Bool>?
        var onPreview: (() -> Void)?
        private var selectionBeforeClick: Bool?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.clickCount == 1 {
                selectionBeforeClick = selection?.wrappedValue
                if allowsSelection, let selection {
                    selection.wrappedValue.toggle()
                }
            } else if event.clickCount == 2 {
                if allowsSelection, let selectionBeforeClick {
                    selection?.wrappedValue = selectionBeforeClick
                }
                selectionBeforeClick = nil
                onPreview?()
            }
        }
    }
}

/// Changes photo matching without another scan.
struct PhotoSimilarityPicker: View {
    @Bindable var model: PhotoDuplicatesModel
    var isDisabled = false

    var body: some View {
        HStack(spacing: 8) {
            if model.isRegrouping {
                ProgressView().controlSize(.small)
            }
            Text("Match")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
            Menu {
                Picker("Match", selection: $model.similarity) {
                    ForEach(PhotoSimilarity.allCases) { similarity in
                        Text(similarityLabel(similarity)).tag(similarity)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 7) {
                    Text(similarityLabel(model.similarity))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.button)
            .buttonStyle(PageActionButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Match")
            .accessibilityValue(similarityLabel(model.similarity))
            .fixedSize()
            .disabled(isDisabled)
            .help(model.similarity.detail
                  + " Bursts and identical copies are unaffected — neither is decided "
                  + "by this number.")
        }
    }

    private func similarityLabel(_ similarity: PhotoSimilarity) -> String {
        similarity.thresholdLabel.isEmpty
            ? similarity.title
            : "\(similarity.title) · \(similarity.thresholdLabel)"
    }

}
