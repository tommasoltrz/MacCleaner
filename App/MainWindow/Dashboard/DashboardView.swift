import SwiftUI
import MacCleanerCore

/// The Dashboard.
///
/// A plain `ScrollView` inside the split view's detail column, which means its
/// content passes under the unified toolbar and blurs against it live. The handoff
/// is emphatic that this is the point — "do not pin content below the toolbar" — so
/// there is no manual top inset here; the platform provides it.
struct DashboardView: View {
    @Bindable var model: AppModel
    /// Optional so previews and the Scanner's empty state need not supply one.
    var settings: SettingsStore?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let volume = model.volume, isLowOnSpace(volume) {
                    lowSpaceBanner(volume)
                }

                if model.isLoadingBreakdown {
                    // Bones, not stale figures: showing yesterday's numbers under a
                    // spinner invites reading them as current.
                    CapacityCardSkeleton()
                } else if let volume = model.volume, let breakdown = model.breakdown {
                    CapacityCard(volume: volume, breakdown: breakdown)
                    if model.breakdownIsStale {
                        staleNote
                    }
                } else {
                    measuringPlaceholder
                }

                StatTiles(
                    results: model.scanResults,
                    onSafeTap: { model.view = .safeToRemove },
                    onReviewTap: { model.view = .needsReview }
                )

                SnapshotsDisclosureRow(
                    snapshots: model.snapshots,
                    isExpanded: $model.snapshotsExpanded
                )
            }
            // Breathing room wins over exact alignment with the toolbar's own inset:
            // at 5pt the cards aligned with the chevron capsule but sat almost
            // against the sidebar. The Scan button is inset to match this figure, so
            // the trailing edges still line up; the leading chevron group cannot be
            // moved (see MainWindow) and is left slightly proud.
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
    }

    /// Acts on Preferences › General › "Warn me below".
    ///
    /// Shown in the window rather than as a system notification: a notification would
    /// need its own permission prompt, and this app already asks the user for more
    /// access than most. The banner appears where the number it refers to lives.
    private func isLowOnSpace(_ volume: VolumeInfo) -> Bool {
        guard let settings else { return false }
        return volume.freeBytes < Int64(settings.warnBelowGB) * ByteFormatting.bytesPerGB
    }

    private func lowSpaceBanner(_ volume: VolumeInfo) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                // The readable orange, not the fill one: on the light banner the
                // system colour all but disappears into its own tint.
                .foregroundStyle(Token.textColor(.orange))
            Text("\(ByteFormatting.string(volume.freeBytes)) free. This is below your "
                 + "\(settings?.warnBelowGB ?? 0) GB warning threshold.")
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.primary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            Token.color(.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: Token.Radius.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(Token.color(.orange).opacity(0.26), lineWidth: Token.hairline)
        )
    }

    /// Says plainly that the figures are remembered rather than fresh. Showing a
    /// stale number as if it were current is the same dishonesty as mislabelling
    /// unattributed space.
    private var staleNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(model.measuredAt.map { "Measured \($0.formatted(.relative(presentation: .named)))" }
                 ?? "Figures are from an earlier session")
        }
        .font(.mcSubtitle)
        .foregroundStyle(Token.Text.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// The first breakdown walks the whole home directory, which takes real time.
    /// Saying so beats an empty card or a spinner with no explanation.
    private var measuringPlaceholder: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Measuring storage…")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                Text("Reading every file's allocated size. Anything unreadable is reported as Unmeasured rather than guessed at.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}
