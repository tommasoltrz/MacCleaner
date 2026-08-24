import SwiftUI
import MacCleanerCore

/// One photograph, large enough to actually judge.
///
/// The grid renders 108pt tiles, and near-duplicates are near-identical at that size
/// — which is the whole difficulty. Deciding to delete a photograph is a decision
/// that needs the picture, so every tile opens here, and the two actions that matter
/// are on this screen rather than back in the grid: keep this copy instead, or mark
/// this one to go.
struct PhotoPreviewSheet: View {
    let item: PhotoDuplicatesView.Preview
    /// Re-resolved from the model each render, so promoting a copy updates the sheet
    /// rather than leaving it showing a stale idea of which one survives.
    let group: DuplicateGroup?
    @Bindable var model: AppModel
    let thumbnails: PhotoThumbnailLoader
    let onClose: () -> Void

    @State private var shown: PhotoAsset

    init(
        item: PhotoDuplicatesView.Preview,
        group: DuplicateGroup?,
        model: AppModel,
        thumbnails: PhotoThumbnailLoader,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.group = group
        self.model = model
        self.thumbnails = thumbnails
        self.onClose = onClose
        _shown = State(initialValue: item.asset)
    }

    private var isKeeper: Bool { shown.id == group?.keeper.id }
    private var isSelected: Bool { model.photoSelection.contains(shown.id) }
    private var siblings: [PhotoAsset] { group?.assets ?? [shown] }

    var body: some View {
        VStack(spacing: 0) {
            header
            image
            footer
        }
        .frame(width: 860, height: 700)
        .background(Token.pageBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isKeeper {
                Badge(text: "Keeping this one", style: .safe)
            } else if isSelected {
                Text("Marked to delete")
                    .font(.mcBadge)
                    .foregroundStyle(Token.textColor(.red))
            }

            if let date = shown.creationDate {
                Text(date, format: .dateTime.day().month().year().hour().minute())
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
            }
            Text("\(shown.pixelWidth) × \(shown.pixelHeight)")
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
            if shown.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Token.textColor(.red))
            }

            Spacer()

            if let index = siblings.firstIndex(where: { $0.id == shown.id }) {
                Text("\(index + 1) of \(siblings.count)")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(siblings.count < 2)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(siblings.count < 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var image: some View {
        ZStack {
            Token.Fill.well
            if let nsImage = thumbnails.preview(for: shown.id) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // The stand-in is the grid's 320px thumbnail, so say so rather than
            // letting a soft image read as a soft photograph — the whole point of
            // opening it is to judge the picture, and that judgement is wrong if it
            // is made against a placeholder.
            if thumbnails.isPreviewLoading(shown.id) {
                VStack(spacing: 8) {
                    if let fraction = thumbnails.downloadProgress[shown.id], fraction > 0 {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 160)
                        Text("Downloading the original from iCloud… \(Int(fraction * 100))%")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading full resolution…")
                    }
                }
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Token.Radius.box))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: shown.id) { thumbnails.loadPreview(shown.id) }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if !isKeeper {
                // The automatic choice is a heuristic; the person looking at the
                // photograph outranks it.
                Button("Keep This One Instead") {
                    guard let group else { return }
                    model.keepInstead(groupID: group.id, assetID: shown.id)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()

            if isKeeper {
                Text("This copy stays. Choose another to keep it instead.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
            } else {
                Button(isSelected ? "Keep This Copy" : "Delete This Copy") {
                    model.togglePhoto(shown.id)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Moves through the group, wrapping — a set of near-identical copies is
    /// something you flick back and forth through, not a list with ends.
    private func step(_ delta: Int) {
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == shown.id })
        else { return }
        let next = (index + delta + siblings.count) % siblings.count
        shown = siblings[next]
    }
}
