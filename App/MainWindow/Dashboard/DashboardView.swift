import SwiftUI
import ScoloCore

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

                if let volume = model.volume, model.isDashboardLoading {
                    // The totals are already known — `diskutil` answers before the
                    // category walk even starts — so only the parts the walk
                    // produces go to bones. The previous breakdown supplies the
                    // category names, which are stable; its figures are withheld:
                    // stale numbers under a pulse read as current.
                    CapacityCard(volume: volume, breakdown: model.breakdown, isMeasuring: true)
                } else if model.isDashboardLoading {
                    // Not even the totals yet: the moment before `diskutil` returns.
                    CapacityCardSkeleton()
                } else if let volume = model.volume, let breakdown = model.breakdown {
                    CapacityCard(volume: volume, breakdown: breakdown)
                    if model.breakdownIsStale {
                        staleNote
                    }
                } else {
                    measuringPlaceholder
                }

                // What to do, beside what changed. The three stat tiles that used
                // to sit here were summaries — each stated a figure and left the
                // user to go and find the thing that acted on it. A suggestion
                // carries the verb, so the row is the action.
                //
                // Stacked, not side by side.
                //
                // The reference puts "what changed" in a narrow right-hand column,
                // and the growth card cannot go there. It has a hard minimum width:
                // its class chips are `fixedSize`, and its folder rows carry a rule
                // that the path truncates before the figure ever does. Put in a
                // 340pt column it drew straight over the suggestions beside it —
                // and `ViewThatFits` chose that layout anyway, because the card's
                // own nested `ViewThatFits` reported an ideal width it then
                // exceeded.
                //
                // A compact variant could be designed for that column, at the cost
                // of the paths, which are the part worth having. Until then both
                // get the width they were drawn for.
                SuggestionList(model: model)
                growthSection

                // After everything about this disk and before the system-level
                // footnotes, matching where the account sits in the user's mental
                // model.
                if let iCloud = model.iCloudStorage {
                    ICloudCard(storage: iCloud)
                        // Re-measures when the plan setting changes, so correcting a
                        // wrong estimate in Preferences is reflected here immediately
                        // rather than at the next launch.
                        .task(id: settings?.iCloudPlan) {
                            model.iCloudPlanBytes = settings?.iCloudPlan.bytes
                            await model.loadICloud()
                        }
                }

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

    /// What the disk did, beside what to do about it.
    ///
    /// It keeps its named folders. A summary of which *categories* grew —
    /// "macOS +10.6 GB" — says a thing happened and nothing a person can act on;
    /// `Documents/Renewals/build +11.0 GB` is the whole point of the measurement
    /// ring, and the rule that finds it (a child is named instead of its parent
    /// only when it explains four fifths of the change) exists to make that line
    /// trustworthy. The figures stay; the bars that would have replaced them do
    /// not, because they are the less useful half.
    ///
    /// No measuring state: the report is dated history, so it stays on screen
    /// while the next walk runs.
    @ViewBuilder
    private var growthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed")
                .font(.mcSectionTitle)
                .foregroundStyle(Token.Text.primary)
            if let growth = model.growth {
                GrowthCard(
                    presentation: GrowthCard.Presentation(growth),
                    baseline: model.growthBaseline,
                    onSelectBaseline: { model.growthBaseline = $0 },
                    onReveal: { model.revealGrowth($0) }
                )
            } else {
                GroupedBox {
                    Text("Scolo compares each measurement with the last one. "
                         + "The first report arrives after the second measurement.")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
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
