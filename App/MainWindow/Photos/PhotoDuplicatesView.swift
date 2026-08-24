import SwiftUI
import MacCleanerCore

/// The duplicate review grid.
///
/// The grid is the feature, not a nicety. Bulk-deleting photographs on the strength
/// of a similarity score is only defensible if the user can see what is going and
/// what is being kept, side by side, before anything happens — so every group shows
/// its keeper next to its casualties at the same size, and the keeper is not
/// selectable from here at all.
struct PhotoDuplicatesView: View {
    /// Which photograph the preview sheet is showing, and the group it came from.
    struct Preview: Identifiable {
        let groupID: String
        let asset: PhotoAsset
        var id: String { asset.id }
    }

    @Bindable var model: AppModel
    @State private var thumbnails = PhotoThumbnailLoader()
    @State private var preview: Preview?

    var body: some View {
        Group {
            if let reason = model.photoUnavailable {
                unavailable(reason)
            } else if model.isSweepingPhotos {
                sweeping
            } else if model.photoResults == nil {
                intro
            } else if model.photoGroups.isEmpty {
                nothingFound
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $preview) { item in
            PhotoPreviewSheet(
                item: item,
                group: model.photoGroups.first { $0.id == item.groupID },
                model: model,
                thumbnails: thumbnails,
                onClose: { preview = nil }
            )
        }
    }

    // MARK: - States

    private var intro: some View {
        // The same system empty state the Scanner and Large & Old Files use, so the
        // app has one idle screen rather than three hand-drawn variations.
        ContentUnavailableView {
            Label("Find duplicate photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Compares every photo in your iCloud library by appearance, not by "
                 + "filename or date. Photos missing a local thumbnail are fetched "
                 + "from iCloud at preview size — originals are never downloaded.")
        } actions: {
            Button("Find Duplicates") { model.startPhotoSweep() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        // The Scanner's empty-state geometry exactly: a 320pt block pinned to the
        // top of the page, not a message floating in the middle of it.
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sweeping: some View {
        centred {
            ProgressView(value: Double(model.photoProgress?.percent ?? 0), total: 100)
                .progressViewStyle(.linear)
                .frame(width: 260)
            Text(progressLabel)
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)
            if let progress = model.photoProgress, progress.fromCache > 0 {
                // Says plainly that the wait is shorter than last time, and why.
                Text("\(progress.fromCache.formatted()) already fingerprinted")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
            }
            Button("Stop") { model.cancelPhotoSweep() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 4)
        }
    }

    private var progressLabel: String {
        guard let progress = model.photoProgress else { return "Preparing…" }
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
        }
    }

    private var nothingFound: some View {
        centred {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Token.textColor(.green))
            Text("No duplicates found")
                .font(.mcToolbarTitle)
                .foregroundStyle(Token.Text.primary)
            if let results = model.photoResults {
                Text(summary(results))
                    .font(.mcBody)
                    .foregroundStyle(Token.Text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Scan Again") { model.startPhotoSweep() }
                .buttonStyle(SecondaryButtonStyle())
        }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let results = model.photoResults, results.skippedCount > 0 {
                    Text(summary(results))
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .padding(.horizontal, 2)
                }
                ForEach(model.photoGroups) { group in
                    groupCard(group)
                }
            }
            .padding(18)
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Badge(text: kindLabel(group.kind), style: group.kind == .similar ? .neutral : .safe)
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
        let selected = model.photoSelection.contains(asset.id)

        return VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                thumbnail(asset)
                    // Tapping the picture opens it. Everything here looks alike at
                    // 108pt, which is precisely why a decision to delete should not
                    // have to be made at 108pt.
                    .onTapGesture { preview = Preview(groupID: group.id, asset: asset) }

                if !isKeeper {
                    // Selection lives on the checkmark alone, so opening a photo to
                    // look at it can never arm or disarm it by accident.
                    Button {
                        model.togglePhoto(asset.id)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                selected ? Color.white : Color.white.opacity(0.9),
                                selected ? Token.color(.red) : Color.black.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help(selected ? "Keep this photo" : "Delete this photo")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous)
                    .strokeBorder(
                        isKeeper ? Token.color(.green).opacity(0.7)
                            : (selected ? Token.color(.red) : Token.Fill.boxBorder),
                        lineWidth: isKeeper || selected ? 2 : 1
                    )
            )
            .contextMenu {
                if !isKeeper {
                    Button("Keep This One Instead") {
                        model.keepInstead(groupID: group.id, assetID: asset.id)
                    }
                }
                Button("Open") { preview = Preview(groupID: group.id, asset: asset) }
            }

            Text(isKeeper ? "Keep" : (selected ? "Delete" : "Keeping"))
                .font(.mcBadge)
                .foregroundStyle(
                    isKeeper ? Token.textColor(.green)
                        : (selected ? Token.textColor(.red) : Token.Text.tertiary)
                )
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
        !group.removable.isEmpty
            && group.removable.allSatisfy { model.photoSelection.contains($0.id) }
    }

    private func toggleGroup(_ group: DuplicateGroup) {
        let ids = group.removable.map(\.id)
        if allSelected(group) {
            model.photoSelection.subtract(ids)
        } else {
            model.photoSelection.formUnion(ids)
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
