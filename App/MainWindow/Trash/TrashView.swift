import SwiftUI
import MacCleanerCore

/// The Trash: what is in it, how much it is holding, and the one destructive button
/// in the app.
///
/// Reading the Trash means measuring every item in it, which is disk work — so it runs
/// from a `.task` rather than on the model's launch path, and the view says it is
/// reading rather than showing an empty box while it does.
struct TrashView: View {
    @Bindable var model: AppModel

    /// Distinguishes "not read yet" from "read, and there was nothing to read".
    /// `AppModel.loadTrash()` swallows its error into `nil`, so without this the
    /// spinner would be indistinguishable from a failure and would never stop.
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if let summary = model.trashSummary {
                TrashContent(
                    summary: summary,
                    onPutBack: { item in Task { await model.putBack(item) } }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if hasLoaded {
                            unreadableNote
                        } else {
                            loadingNote
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 22)
                }
            }
        }
        .task {
            await model.loadTrash()
            hasLoaded = true
        }
    }

    private var loadingNote: some View {
        GroupedBox {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the Trash…")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                Text("Every item is measured on disk, so a Trash with large folders in it takes a moment.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var unreadableNote: some View {
        ContentUnavailableView {
            Label("The Trash could not be read", systemImage: "trash.slash")
        } description: {
            // This is the system Trash — the same one Finder shows — but reading it
            // is gated behind Full Disk Access. Say how to fix it, per the same rule
            // that gave Docker's disabled row its "start it to measure" subtitle.
            Text("This is the same Trash Finder shows, but macOS only lets apps with "
                 + "Full Disk Access look inside it. Grant access in System Settings "
                 + "and come back.")
        } actions: {
            Button("Open System Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

// MARK: - Card and list

/// Everything that renders from a loaded summary, split out so the previews can show
/// real states without a Trash on disk.
private struct TrashContent: View {
    let summary: TrashSummary
    let onPutBack: (TrashItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if summary.items.isEmpty {
                        emptyNote
                    } else {
                        // Finder's Bin also shows iCloud's Recently Deleted, which are cloud
                        // records with no bytes on this disk. Saying so heads off "why does
                        // Finder show more items" — the honest scope here is this disk.
                        if hasICloudDrive {
                            Text("Finder's Bin may also show iCloud's Recently Deleted. Those "
                                 + "items live in iCloud, not on this disk.")
                                .font(.mcSubtitle)
                                .foregroundStyle(Token.Text.tertiary)
                                .padding(.horizontal, 2)
                        }
                        GroupedBox {
                            // Lazy: `TrashService` caps the rows it returns, but the cap is 50 and
                            // each row carries a button and a hover tracker.
                            LazyVStack(spacing: 0) {
                                ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Hairline() }
                                    TrashRow(item: item, onPutBack: { onPutBack(item) })
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                        }

                        // Finder shows every item; this list deliberately shows the biggest.
                        // Said out loud, or the shorter list reads as missing files.
                        if summary.itemCount > summary.items.count {
                            Text("Showing the \(summary.items.count) largest of "
                                 + "\(summary.itemCount) items. Finder lists them all.")
                                .font(.mcSubtitle)
                                .foregroundStyle(Token.Text.tertiary)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 22)
            }
        }
    }

    // MARK: Summary header

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trash")
                .mcEyebrowStyle()

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(ByteFormatting.string(summary.totalBytes))
                    .font(.mcSecondaryHero)
                    .mcTracked(-0.26)   // -0.01em
                    .foregroundStyle(Token.Text.emphasis)
                    .lineLimit(1)

                Text("· \(summary.itemCount) \(summary.itemCount == 1 ? "item" : "items")")
                    .font(.trashItemCount)
                    .foregroundStyle(Token.Text.quaternary)
                    .lineLimit(1)
            }

            Text("How long items remain here is controlled by Finder settings.")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }

    private var hasICloudDrive: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        )
    }

    private var emptyNote: some View {
        ContentUnavailableView {
            Label("The Trash is empty", systemImage: "trash")
        } description: {
            // "This app's trash" is a misreading worth preventing: it is ~/.Trash,
            // the same one in Finder's Dock.
            Text("This is the system Trash, the same one Finder shows. Items this "
                 + "app moves here record their original location. You can put "
                 + "them back.")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

// MARK: - One row

private struct TrashRow: View {
    let item: TrashItem
    let onPutBack: () -> Void

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Text(item.name)
                .font(.mcBody)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.url.path)

            Text(deletedText)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.quaternary)
                .lineLimit(1)
                .frame(width: Metrics.deleted, alignment: .leading)

            Text(ByteFormatting.string(item.bytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Metrics.size, alignment: .trailing)

            putBack
        }
        .padding(.horizontal, Metrics.sidePadding)
        .frame(height: Token.Size.trashRow)
        .contentShape(Rectangle())
        .hoverHighlight()
    }

    /// The tooltip hangs on the wrapper rather than the button: a disabled control is
    /// exactly the case where the reason matters most, and a greyed button that cannot
    /// explain itself is worse than no button at all.
    private var putBack: some View {
        HStack(spacing: 0) {
            Button("Put Back", action: onPutBack)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!item.canPutBack)
        }
        .help(putBackHelp)
        .accessibilityHint(putBackHelp)
    }

    /// macOS publishes no API for where a trashed item came from — Finder keeps that
    /// privately — so MacCleaner can only restore what its own removal log recorded.
    /// Anything dragged in from Finder is Finder's to put back.
    private var putBackHelp: String {
        item.canPutBack
            ? "Move this back to the folder MacCleaner removed it from."
            : "MacCleaner did not move this to the Trash, and macOS does not say where a trashed item came from. Use Finder's Put Back for this one."
    }

    /// `nil` renders as no caption rather than an invented date.
    @MainActor
    private var deletedText: String {
        guard let deletedAt = item.deletedAt else { return "" }
        guard Date.now.timeIntervalSince(deletedAt) >= 60 else { return "Deleted just now" }
        return "Deleted " + deletedFormatter.localizedString(for: deletedAt, relativeTo: .now)
    }
}

// MARK: - Shared parts

private enum Metrics {
    static let sidePadding: CGFloat = 15
    static let gap: CGFloat = 11
    /// Fixed, so the dates and figures hold their columns and growth goes to the name.
    static let deleted: CGFloat = 140
    static let size: CGFloat = 78
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }
}

/// One formatter, not one per row — building these is expensive.
@MainActor private let deletedFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named   // "yesterday" over "1 day ago"
    return formatter
}()

/// 15pt belongs to this card alone, so it is not in the shared ramp — but it carries a
/// figure, so it carries tabular digits.
private extension Font {
    static let trashItemCount = Font.system(size: 15).monospacedDigit()
}

// MARK: - Previews
//
// These render `TrashContent` rather than `TrashView`: the view's `.task` reads the
// real `~/.Trash`, which would replace any fixture the moment the preview appeared.

#Preview("Trash") {
    TrashContent(
        summary: PreviewTrash.populated,
        onPutBack: { _ in }
    )
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

#Preview("Trash — empty") {
    TrashContent(summary: TrashSummary(), onPutBack: { _ in })
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

/// The design's own sample rows. Only the first was trashed by this app, so it is the
/// only one whose Put Back is live — which is the state the real Trash is usually in.
private enum PreviewTrash {
    private static func trash(_ name: String) -> URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".Trash/\(name)")
    }
    private static func daysAgo(_ days: Double) -> Date {
        Date.now.addingTimeInterval(-days * 86_400)
    }

    static let populated = TrashSummary(
        totalBytes: 9_040_162_816,
        itemCount: 214,
        items: [
            TrashItem(
                url: trash("Sketch 2019 Backups"),
                bytes: 4_402_341_478,
                deletedAt: daysAgo(2),
                canPutBack: true
            ),
            TrashItem(
                url: trash("iPhone 12 backup 2023-04-11"),
                bytes: 3_049_205_924,
                deletedAt: daysAgo(5)
            ),
            TrashItem(
                url: trash("Figma-export-final-v7.zip"),
                bytes: 1_034_140_058,
                deletedAt: daysAgo(11)
            ),
            // No date: `.addedToDirectoryDateKey` is missing on some items, and the row
            // simply carries no caption.
            TrashItem(url: trash("Zoom.pkg"), bytes: 536_870_912)
        ]
    )
}
