import SwiftUI
import MacCleanerCore

/// Preferences → Categories: which categories the Scanner is allowed to measure.
struct CategoriesPane: View {

    let settings: SettingsStore

    /// Sizes from the last scan. A category missing from this map has never been
    /// measured and renders an em dash.
    var sizes: [CategoryID: Int64] = [:]

    private enum Metrics {
        /// The design's gap below the intro and above the callout. Uniform, so the
        /// pane's stack carries it rather than each child.
        static let gap: CGFloat = 14
        static let rowGap: CGFloat = 11
        /// Sizes form a right-aligned column, so the switches stay in line whether the
        /// row reads `1.63 GB` or `—`.
        static let sizeColumn: CGFloat = 66
        static let calloutPaddingH: CGFloat = 13
        static let calloutPaddingV: CGFloat = 10
    }

    var body: some View {
        PrefPane(spacing: Metrics.gap) {
            Text(
                "Categories that are off are never measured and never appear in the "
                + "Scanner. Turning a category off does not delete anything."
            )
            .font(.mcBody)
            .foregroundStyle(Token.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(Array(CategoryID.allCases.enumerated()), id: \.element) { index, category in
                        if index > 0 { PrefDivider() }
                        row(for: category)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
            }

            if !hiddenCategories.isEmpty { warningCallout }
        }
    }

    // MARK: - Rows

    private func row(for category: CategoryID) -> some View {
        HStack(spacing: Metrics.rowGap) {
            CategoryDot(color: category.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PrefMetrics.labelGap) {
                Text(category.displayName)
                    .font(.mcRowTitleRegular)
                    .foregroundStyle(Token.Text.primary)
                Text(category.subtitle)
                    .font(category.subtitleIsPath ? .mcMonoPath : .mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(category.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText(for: category))
                .font(.mcControlLabel.monospacedDigit())
                .foregroundStyle(Token.Text.tertiary)
                .frame(width: Metrics.sizeColumn, alignment: .trailing)

            Toggle(isOn: settings.enabledBinding(for: category)) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text(category.displayName))
                .accessibilityValue(Text(sizeText(for: category)))
        }
        .padding(.horizontal, PrefMetrics.rowPaddingH)
        .padding(.vertical, PrefMetrics.rowPaddingV)
        .frame(maxWidth: .infinity, minHeight: PrefMetrics.rowHeight)
    }

    /// An em dash for anything unmeasured. `0 B` is a claim — that the category was
    /// looked at and found clean — and it is not one this pane can make before a scan.
    private func sizeText(for category: CategoryID) -> String {
        guard let bytes = sizes[category] else { return "—" }
        return ByteFormatting.string(bytes)
    }

    // MARK: - Warning callout

    /// Every category that is switched off but is known to hold something.
    ///
    /// A category with no measurement is not listed: there is nothing to warn about
    /// hiding, and naming a size we do not have would be worse than saying nothing.
    private var hiddenCategories: [(category: CategoryID, bytes: Int64)] {
        CategoryID.allCases.compactMap { category in
            guard !settings.isEnabled(category),
                  let bytes = sizes[category], bytes > 0
            else { return nil }
            return (category, bytes)
        }
    }

    /// The design's conditional warning.
    ///
    /// It exists because "off" means *not measured*, which reads as *deleted* to
    /// anyone who has not been told otherwise — so the copy has to say where the bytes
    /// went and where they still show up. The sentence names every category currently
    /// hidden, not just the first: a warning that mentions one of two understates the
    /// number the user is about to stop seeing.
    private var warningCallout: some View {
        let hidden = hiddenCategories
        let names = hidden.map { $0.category.displayName }.formatted(.list(type: .and))
        let total = hidden.reduce(0) { $0 + $1.bytes }
        // One literal, not concatenated pieces: the emphasised run is a `Text`
        // interpolation, which only works inside a single string literal.
        let sentence = Text("""
            Turning off \
            \(Text(names).foregroundStyle(Token.Text.emphasis).fontWeight(.medium)) \
            hides \(ByteFormatting.string(total)) from the Scanner. \
            Your Dashboard totals will still include it.
            """)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15))
                // The readable orange: the glyph sits on its own orange tint, which
                // leaves the system colour with nothing to stand against in light.
                .foregroundStyle(Token.textColor(.orange))
                .accessibilityHidden(true)

            sentence
                .font(.mcSubtitle)
                .lineSpacing(3)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.calloutPaddingH)
        .padding(.vertical, Metrics.calloutPaddingV)
        .background(
            Token.color(.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: Token.Radius.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(Token.color(.orange).opacity(0.26), lineWidth: Token.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview("Categories") {
    // Two categories off, one of them measured — which is what raises the callout.
    CategoriesPane(
        settings: .preview(),
        sizes: [
            .documentsAndFiles: 42_036_992_410,
            .applications: 24_674_587_115,
            .hiddenSystemData: 3_747_294_413,
            .systemCaches: 1_750_199_173,
            .packageManagers: 516_726_784,
            .xcode: 0
        ]
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
