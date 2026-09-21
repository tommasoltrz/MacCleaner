import SwiftUI
import ScoloCore

/// What the Dashboard offers to do about what it just measured.
///
/// It replaced three stat tiles — "Safe to remove", "Needs review", "Last scan" —
/// which were summaries: each stated a figure and left the user to find the thing
/// that acted on it. A suggestion states the same figure and carries the verb, so
/// the row is the action rather than a signpost to it.
///
/// **Nothing here invents a number.** Three of these rows are readings from a junk
/// scan and the fourth from a photo sweep, which is a separate operation the user
/// may never have run. Without the measurement behind it, a row keeps its name and
/// its description — that much is true whatever the disk holds — and offers to go
/// and look. It does not show a figure it does not have, and it does not guess one
/// from the last time.
struct SuggestionList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    row(suggestion)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Suggestions")
                .font(.mcSectionTitle)
                .foregroundStyle(Token.Text.primary)
            Spacer(minLength: 8)
            // Where the "Last scan" tile's figure went. It is a caption on the
            // section it dates rather than a card of its own: the freshness of a
            // reading belongs to the reading.
            Text(scanAge)
                .font(.mcCaption)
                .foregroundStyle(Token.Text.tertiary)
            Button(model.scanResults == nil ? "Scan" : "Scan Again") { model.startScan() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusyWithDisk)
        }
    }

    private var scanAge: String {
        guard let at = model.lastScanFinishedAt else { return "Not scanned yet" }
        return "Scanned \(at.formatted(.relative(presentation: .named)))"
    }

    private func row(_ suggestion: Suggestion) -> some View {
        GroupedBox {
            HStack(spacing: 12) {
                Image(systemName: suggestion.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Token.textColor(suggestion.tint))
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.box, style: .continuous)
                            .fill(Token.color(suggestion.tint).opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text(suggestion.detail)
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if let figure = suggestion.figure {
                    Text(figure)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                        .monospacedDigit()
                        // The figure never wraps onto two lines. A size that
                        // breaks mid-unit reads as two numbers.
                        .lineLimit(1)
                        .fixedSize()
                }

                Button(suggestion.actionLabel, action: suggestion.action)
                    .buttonStyle(suggestion.isPrimary
                                 ? AnyButtonStyle(DestructiveButtonStyle())
                                 : AnyButtonStyle(SecondaryButtonStyle()))
                    .disabled(suggestion.isDisabled)
                    .fixedSize()
            }
            .padding(12)
        }
    }

    // MARK: - What there is to suggest

    private struct Suggestion: Identifiable {
        let id: String
        let symbol: String
        let tint: ColorToken
        let title: String
        let detail: String
        /// Absent until something has measured it.
        let figure: String?
        let actionLabel: String
        var isPrimary = false
        var isDisabled = false
        let action: () -> Void
    }

    private var suggestions: [Suggestion] {
        let results = model.scanResults
        let busy = model.isBusyWithDisk

        let safeBytes = results?.safeToRemoveBytes ?? 0
        let caches = Suggestion(
            id: "safe",
            symbol: "checkmark.shield",
            tint: .green,
            title: "Caches & leftovers",
            detail: results == nil
                ? "Rebuilt on demand. A scan finds what is here."
                : "They rebuild themselves. Nothing you will miss.",
            figure: results.map { _ in ByteFormatting.string(safeBytes) },
            actionLabel: results == nil ? "Scan" : "Clean",
            isPrimary: results != nil && safeBytes > 0,
            isDisabled: busy || (results != nil && safeBytes == 0)
        ) {
            if results == nil { model.startScan() } else { model.cleanSafeToRemove() }
        }

        let documents = category(.documentsAndFiles)
        let largest = Suggestion(
            id: "documents",
            symbol: "folder",
            tint: .orange,
            // Folders, not files. The biggest single *file* on the disk is a
            // different question and Scolo cannot answer it yet.
            title: "Biggest folders",
            detail: "In Documents, Downloads, Desktop, Movies, Pictures and Music.",
            figure: documents.map { ByteFormatting.string($0.totalBytes) },
            actionLabel: documents == nil ? "Scan" : "Review",
            isDisabled: busy
        ) {
            if documents == nil { model.startScan() }
            else { model.showScanner(category: .documentsAndFiles) }
        }

        let applications = category(.applications)
        let apps = Suggestion(
            id: "applications",
            symbol: "square.grid.2x2",
            tint: .accent,
            title: "Apps you rarely open",
            detail: "Sorted by when you last used them.",
            figure: applications.map { ByteFormatting.string($0.totalBytes) },
            actionLabel: applications == nil ? "Scan" : "Review",
            isDisabled: busy
        ) {
            if applications == nil { model.startScan() }
            else { model.showScanner(category: .applications) }
        }

        let photos = model.photoResults
        let lookAlike = Suggestion(
            id: "photos",
            symbol: "photo.on.rectangle",
            tint: .purple,
            title: "Look-alike photos",
            // No size, and there cannot be one: PhotoKit exposes no bytes for an
            // asset without downloading the original. This feature counts
            // photographs and never claims storage.
            detail: photos.map { results in
                results.removableCount == 0
                    ? "Nothing that looks like a duplicate."
                    : "\(results.removableCount) copies marked. The originals stay put."
            } ?? "Compared by appearance, not by name or date.",
            figure: nil,
            actionLabel: photos == nil ? "Find" : "Review",
            isDisabled: busy
        ) {
            if photos == nil { model.startPhotoSweep() }
            else { model.showDuplicates(kind: .photos) }
        }

        return [caches, largest, apps, lookAlike]
    }

    private func category(_ id: CategoryID) -> ScanCategoryResult? {
        guard let category = model.scanResults?.categories.first(where: { $0.categoryID == id }),
              category.totalBytes > 0
        else { return nil }
        return category
    }
}

/// Lets one row choose between two button styles without the branch changing the
/// view's type, which `ViewBuilder` will not do inside a modifier.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
