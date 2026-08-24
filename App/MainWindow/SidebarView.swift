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

    /// The row the user just pressed, before the app has moved there.
    ///
    /// The pill, the accent label and the filled icon all read this first and
    /// `model.view` second, which is what lets the highlight arrive a frame ahead of the
    /// content. It is set on mouse down and cleared the moment the view actually changes,
    /// so it is never more than one frame out of step with the app.
    @State private var pendingView: AppModel.View?

    var body: some View {
        // Selection is drawn by hand rather than handed to `List`. Finder's dark
        // sidebar selects with a neutral gray fill — exactly the design's
        // `selection-sidebar` token — but SwiftUI's list selection paints the accent
        // colour and offers no way to change it (`listItemTint(.monochrome)` tints
        // row *content*, not the selection fill).
        List {
            Section("MacCleaner") {
                ForEach(AppModel.View.sidebarCases) { view in
                    Button {
                        select(view)
                    } label: {
                        Label {
                            HStack {
                                Text(view.title)
                                    // App Store's treatment, per the user's call over
                                    // Finder's: the selected row's label and icon go
                                    // accent, everything else stays white.
                                    .foregroundStyle(isSelected(view)
                                        ? Token.Fill.sidebarSelectedTint : Token.Text.primary)
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
                                // The App Store fills the selected row's symbol —
                                // outline at rest, solid when chosen — and the solid
                                // glyph is most of why its selection reads brighter.
                                // Symbols with no fill variant keep their outline.
                                .symbolVariant(isSelected(view) ? .fill : .none)
                                .foregroundStyle(isSelected(view)
                                    ? Token.Fill.sidebarSelectedTint : Token.Text.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    // Not `.plain`: that style fades the label while the mouse is
                    // held, and a source list has no pressed state at all.
                    .buttonStyle(SidebarRowButtonStyle())
                    // Zero minimum duration, so this is a press recogniser rather than
                    // a long press: it runs the instant the mouse goes down. A `Button`
                    // acts on mouse *up*, which left the row looking stuck until the
                    // release; Finder switches on the way down, and so does this. The
                    // `Button`'s own action stays for keyboard and assistive
                    // activation, where there is no mouse to go down. Scrolling is
                    // untouched — a wheel or a two-finger swipe is not a press — and
                    // dragging more than 4pt away only ends a selection already made.
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 4) { isPressing in
                        if isPressing { select(view) }
                    } perform: {}
                    .listRowBackground(
                        // Inset, so the pill floats inside the sidebar instead of
                        // running edge to edge.
                        RoundedRectangle(cornerRadius: Token.Radius.row)
                            .fill(isSelected(view) ? Token.Fill.sidebarSelection : .clear)
                            .padding(.horizontal, 10)
                    )
                    .accessibilityAddTraits(isSelected(view) ? .isSelected : [])
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
        // Anything that moves the app without going through a row — the Dashboard's
        // tiles, and the Back button that returns from them — lands here. Clearing the
        // pending row on every change keeps the pill from being held on a view the app
        // has already left, and it is also what ends the normal press: the commit below
        // changes the view, this clears the pending row, and both land in the same
        // update, so the pill never moves twice.
        .onChange(of: model.view) { pendingView = nil }
        .safeAreaInset(edge: .bottom, spacing: 0) { capacityFooter }
    }

    /// Moves to a view, or does nothing if the app is already showing it or already on
    /// its way there. A write of the same value would still publish a change and push a
    /// no-op onto the history.
    ///
    /// The move happens in two steps, one frame apart, and that is the whole point.
    /// Writing `model.view` on mouse down rebuilds the pill and the content pane in a
    /// single update, so the pill appears only once the new view's first frame is ready.
    /// On a heavy section that is long enough to read as a lag, and the click feels like
    /// it was dropped. Finder moves the highlight at once and lets the content catch up.
    ///
    /// So `pendingView` is written first, synchronously, and it drives nothing but the
    /// sidebar: the pill, the accent label and the filled icon. That update is cheap and
    /// commits on the next frame. `model.view`, which rebuilds the content pane, is
    /// written on the following turn of the run loop, once that frame is out.
    ///
    /// A sleep rather than `Task.yield()`, which can resume inside the same run loop pass
    /// that handled the mouse and coalesce the two writes back into one update. One
    /// millisecond lands on a later pass, after SwiftUI has handed the sidebar's frame to
    /// the window server, so the content pane's build no longer holds the pill back.
    ///
    /// Measured in Renewals, which shares this sidebar and has a heavier destination than
    /// anything here: from the mouse down, the pill is on screen at 50 ms and the new
    /// section's own first frame at 816 ms. Writing the model straight from the press put
    /// both at 594 ms.
    ///
    /// The latest press wins. Pressing a second row before the first has committed leaves
    /// the first commit looking at a pending row that is no longer its own, and it stands
    /// down; the second one commits for both.
    private func select(_ view: AppModel.View) {
        guard (pendingView ?? model.view) != view else { return }
        pendingView = view
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            guard pendingView == view else { return }
            model.view = view
            pendingView = nil
        }
    }

    /// What the sidebar draws as chosen: the pressed row if there is one, the app's own
    /// view otherwise.
    private func isSelected(_ view: AppModel.View) -> Bool {
        (pendingView ?? model.view) == view
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
