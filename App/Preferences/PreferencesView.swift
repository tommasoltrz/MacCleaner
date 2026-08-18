import SwiftUI
import MacCleanerCore

/// The preferences window: four tabs behind ⌘,.
///
/// Built as the root of the app's `Settings` scene, which is where the native
/// preferences toolbar, the ⌘, key equivalent and the height animation between panes
/// come from — the design asks for `NSToolbar` in `.preference` style, and this is it.
/// Nothing here draws a tab bar.
///
/// The design's fixed 660 × 484 is assembled from the panes: each is 660 × 432 and the
/// 52pt toolbar sits above. The scene needs `.windowResizability(.contentSize)` for
/// that to hold — "Not resizable" is part of the design, and without it AppKit lets
/// the window be dragged wider than any of its content.
struct PreferencesView: View {

    let settings: SettingsStore

    /// Per-category sizes from the last scan. A category the caller has no figure for
    /// renders an em dash: `0 B` would claim it was measured and found clean.
    var categorySizes: [CategoryID: Int64] = [:]

    /// Supplied by the caller because both outlive the window: rebuilding walks the
    /// disk, and a reset has to clear scan state the store knows nothing about.
    var onRebuildIndex: (() -> Void)?
    var onResetSettings: (() -> Void)?

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            CategoriesPane(settings: settings, sizes: categorySizes)
                .tabItem { Label("Categories", systemImage: "square.grid.2x2") }

            ExclusionsPane(settings: settings)
                .tabItem { Label("Exclusions", systemImage: "lock") }

            AdvancedPane(
                settings: settings,
                onRebuildIndex: onRebuildIndex,
                onResetSettings: onResetSettings
            )
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
    }
}

// MARK: - Shared metrics

/// The preferences section pattern, in numbers. Every pane measures from here so the
/// four of them line up when the toolbar switches between them.
enum PrefMetrics {
    static let paneWidth: CGFloat = 660
    /// 484 window − 52 toolbar. The design gives it as "min-height 432px".
    static let paneHeight: CGFloat = 432

    static let contentPaddingH: CGFloat = 26
    static let contentPaddingV: CGFloat = 22
    static let sectionGap: CGFloat = 20
    static let headerGap: CGFloat = 9

    static let rowPaddingH: CGFloat = 14
    static let rowPaddingV: CGFloat = 11
    static let rowHeight: CGFloat = 44
    /// Between a row's label and its description.
    static let labelGap: CGFloat = 3
    /// Between the label block and the control.
    static let controlGap: CGFloat = 12

    /// The design's 0.03em at 12pt.
    static let headerTracking: CGFloat = 0.36
}

// MARK: - Pane shell

/// One tab's content: the fixed pane size and the content-area padding.
struct PrefPane<Content: View>: View {
    var spacing: CGFloat = PrefMetrics.sectionGap
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
            // Sections stack from the top; the pane never centres them, whichever tab
            // is shortest.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PrefMetrics.contentPaddingH)
        .padding(.vertical, PrefMetrics.contentPaddingV)
        .frame(
            width: PrefMetrics.paneWidth,
            height: PrefMetrics.paneHeight,
            alignment: .topLeading
        )
    }
}

// MARK: - Section

/// An uppercase header over a grouped box of rows.
struct PrefSection<Rows: View>: View {
    private let title: String
    private let rows: Rows

    init(_ title: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrefMetrics.headerGap) {
            Text(title)
                .font(.mcSectionHeader)
                .tracking(PrefMetrics.headerTracking)
                .textCase(.uppercase)
                .foregroundStyle(Token.Text.quaternary)
                .accessibilityAddTraits(.isHeader)

            GroupedBox {
                VStack(spacing: 0) { rows }
                    .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
            }
        }
    }
}

/// The hairline between rows of a grouped box.
///
/// Not `Divider()`: that one insets itself and picks its own colour, and the design's
/// row separator runs the full width of the box.
struct PrefDivider: View {
    var body: some View {
        Rectangle()
            .fill(Token.separator)
            .frame(height: Token.hairline)
    }
}

// MARK: - Rows

/// A label, an optional description and a right-aligned control.
struct PrefRow<Control: View>: View {
    let title: String
    var description: String?
    /// Paths render in monospace, per the design's `removals.log` row.
    var descriptionIsPath = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: PrefMetrics.controlGap) {
            PrefLabel(
                title: title,
                description: description,
                descriptionIsPath: descriptionIsPath
            )
            Spacer(minLength: PrefMetrics.controlGap)
            control
        }
        .padding(.horizontal, PrefMetrics.rowPaddingH)
        .padding(.vertical, PrefMetrics.rowPaddingV)
        .frame(maxWidth: .infinity, minHeight: PrefMetrics.rowHeight)
    }
}

/// The label block shared by every row shape, including the ones that are not
/// `PrefRow` (the permissions status row, the reset row).
struct PrefLabel: View {
    let title: String
    var description: String?
    var descriptionIsPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: PrefMetrics.labelGap) {
            Text(title)
                .font(.mcRowTitleRegular)
                .foregroundStyle(Token.Text.primary)

            if let description {
                Text(description)
                    .font(descriptionIsPath ? .mcMonoPath : .mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    // Descriptions wrap rather than truncate — every one of them is the
                    // sentence that says what the switch actually does.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row whose control is a switch.
struct PrefToggleRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    var body: some View {
        PrefRow(title: title, description: description) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                // The visible label lives in the row, so VoiceOver is told separately.
                .accessibilityLabel(Text(title))
        }
    }
}

/// A row whose control is a segmented picker over a `CaseIterable` choice.
struct PrefPickerRow<Choice>: View
where Choice: CaseIterable & Hashable & Identifiable, Choice.AllCases: RandomAccessCollection {
    let title: String
    var description: String?
    @Binding var selection: Choice
    let label: (Choice) -> String

    var body: some View {
        PrefRow(title: title, description: description) {
            Picker(title, selection: $selection) {
                ForEach(Choice.allCases) { choice in
                    Text(label(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Segmented controls stretch to fill by default; the design's sit at their
            // natural width against the trailing edge.
            .fixedSize()
            .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - Preview

#Preview("Preferences") {
    PreferencesView(
        settings: .preview(),
        categorySizes: [
            .systemCaches: 1_750_199_173,
            .packageManagers: 516_726_784,
            .applications: 24_674_587_115,
            .hiddenSystemData: 3_747_294_413
        ]
    )
    .preferredColorScheme(.dark)
}
