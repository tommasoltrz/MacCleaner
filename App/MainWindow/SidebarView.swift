import SwiftUI
import MacCleanerCore

/// The source list.
///
/// A stock `List` with `.sidebar` style, which on macOS 26 supplies the design's
/// tier-1 glass — the real behind-window sidebar material — for free. The handoff
/// explicitly says to drop its hand-drawn gradients and inset highlights in favour of
/// this: they exist only because a browser cannot reach `NSVisualEffectView`.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        // Selection is drawn by hand rather than handed to `List`. Finder's dark
        // sidebar selects with a neutral gray fill — exactly the design's
        // `selection-sidebar` token — but SwiftUI's list selection paints the accent
        // colour and offers no way to change it (`listItemTint(.monochrome)` tints
        // row *content*, not the selection fill).
        List {
            Section("MacCleaner") {
                ForEach(AppModel.View.allCases) { view in
                    Button {
                        model.view = view
                    } label: {
                        Label {
                            HStack {
                                Text(view.title)
                                    // App Store's treatment, per the user's call over
                                    // Finder's: the selected row's label and icon go
                                    // accent, everything else stays white.
                                    .foregroundStyle(model.view == view
                                        ? Token.color(.accent) : Token.Text.primary)
                                Spacer()
                                if let count = count(for: view) {
                                    Text(count, format: .number)
                                        .font(.mcSidebarCount)
                                        .foregroundStyle(Token.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: view.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(model.view == view
                                    ? Token.color(.accent) : Token.Text.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        // Inset, so the pill floats inside the sidebar instead of
                        // running edge to edge.
                        RoundedRectangle(cornerRadius: Token.Radius.row)
                            .fill(model.view == view ? Token.Fill.sidebarSelection : .clear)
                            .padding(.horizontal, 10)
                    )
                    .accessibilityAddTraits(model.view == view ? .isSelected : [])
                }
            }

            Section("Locations") {
                Label {
                    Text(model.volume?.name ?? "Macintosh HD")
                } icon: {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Token.Text.secondary)
                }
                // Labels the scope of every scan rather than navigating anywhere.
                .foregroundStyle(Token.Text.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { capacityFooter }
    }

    /// Free-space readout pinned under the list.
    private var capacityFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(model.volume?.name ?? "Macintosh HD")
                Spacer()
                Text(model.volume.map { "\(ByteFormatting.string($0.freeBytes)) free" } ?? "—")
            }
            .font(.mcEyebrow)
            .foregroundStyle(Token.Text.tertiary)

            ProgressView(value: usedFraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var usedFraction: Double {
        guard let volume = model.volume, volume.capacityBytes > 0 else { return 0 }
        return Double(volume.usedBytes) / Double(volume.capacityBytes)
    }

    /// The design shows a count beside Scanner and Trash only.
    private func count(for view: AppModel.View) -> Int? {
        switch view {
        case .scanner:
            let categories = model.scanResults?.actionableCategories.count ?? 0
            return categories > 0 ? categories : nil
        case .trash:
            let items = model.trashSummary?.itemCount ?? 0
            return items > 0 ? items : nil
        default:
            return nil
        }
    }
}
