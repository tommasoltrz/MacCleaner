import SwiftUI
import UniformTypeIdentifiers
import MacCleanerCore

/// Preferences → Exclusions: the paths and patterns every scan skips.
struct ExclusionsPane: View {

    let settings: SettingsStore

    @State private var selection: Set<ExclusionRule.ID> = []
    @State private var isImportingFolders = false

    private enum Metrics {
        /// The base rhythm of the pane; the two children that need the design's wider
        /// gaps add the difference themselves.
        static let gap: CGFloat = 9
        static let introExtraGap: CGFloat = 5      // 9 + 5 = the design's 14
        static let protectExtraGap: CGFloat = 9    // 9 + 9 = the design's 18
        static let rowHeight: CGFloat = 34
        /// Five rows, which is what the design's well shows without scrolling.
        static let listHeight: CGFloat = 170
        static let rowGap: CGFloat = 10
        static let iconWidth: CGFloat = 14
    }

    var body: some View {
        PrefPane(spacing: Metrics.gap) {
            Text("Anything below is skipped by every scan. Drag folders in from Finder, or use the buttons.")
                .font(.mcBody)
                .foregroundStyle(Token.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Metrics.introExtraGap)

            rulesList
            listControls
            protectRow.padding(.top, Metrics.protectExtraGap)
        }
        .fileImporter(
            isPresented: $isImportingFolders,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            // A cancelled or failed panel changes nothing; there is no error worth
            // interrupting the window for.
            if case .success(let urls) = result { settings.addFolders(urls) }
        }
    }

    // MARK: - List

    private var rulesList: some View {
        Well {
            List(selection: $selection) {
                ForEach(settings.exclusions) { rule in
                    ruleRow(rule)
                        .listRowInsets(EdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 13))
                }
            }
            .listStyle(.plain)
            // The design's recessed well shows through: `List` paints its own
            // background over it otherwise. Separators and the selection fill are
            // left stock.
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Metrics.rowHeight)
            .frame(height: Metrics.listHeight)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.well))
        .dropDestination(for: URL.self) { urls, _ in
            settings.addFolders(urls)
        }
    }

    private func ruleRow(_ rule: ExclusionRule) -> some View {
        HStack(spacing: Metrics.rowGap) {
            Image(systemName: rule.symbol)
                .font(.system(size: 13))
                // Folders are blue as they are in Finder; patterns are not files, so
                // they stay neutral.
                .foregroundStyle(
                    rule.kind == .folder ? Token.color(.accent) : Token.Text.quaternary
                )
                .frame(width: Metrics.iconWidth)

            Text(rule.displayValue)
                .font(.mcMonoPath)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rule.displayValue)

            Spacer(minLength: Metrics.rowGap)

            if let qualifier = rule.qualifier {
                Text(qualifier)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.disabled)
                    .layoutPriority(-1)
            }
        }
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Controls

    private var listControls: some View {
        HStack(spacing: 6) {
            Button {
                isImportingFolders = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add a folder to exclude")

            Button {
                settings.remove(ids: selection)
                selection.removeAll()
            } label: {
                Image(systemName: "minus")
            }
            .disabled(!settings.canRemove(ids: selection))
            .accessibilityLabel("Remove the selected exclusion")

            Spacer(minLength: PrefMetrics.controlGap)

            // The design also carries a "18.2 GB currently protected" figure here.
            // Nothing measures that yet, and a number invented for the line would be
            // the one thing on this pane the user could not verify.
            Text(settings.exclusions.count == 1 ? "1 rule" : "\(settings.exclusions.count) rules")
                .font(.mcSubtitle.monospacedDigit())
                .foregroundStyle(Token.Text.quaternary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Recency window

    private var protectRow: some View {
        GroupedBox {
            PrefPickerRow(
                title: "Protect files opened in the last",
                description: "Recently used files never appear as removal candidates.",
                selection: protectBinding,
                label: \.displayName
            )
        }
    }

    private var protectBinding: Binding<ProtectWindow> {
        Binding(
            get: { settings.protectRecentDays },
            set: { settings.protectRecentDays = $0 }
        )
    }
}

// MARK: - Preview

#Preview("Exclusions") {
    // Folders that exist on every Mac — `addFolders` drops anything that is not a
    // directory, so a made-up path would silently produce an empty list.
    ExclusionsPane(
        settings: .preview {
            $0.addFolders([URL.homeDirectory.appending(path: "Library"), URL(filePath: "/Applications")])
            $0.addPattern("*.dmg")
        }
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
