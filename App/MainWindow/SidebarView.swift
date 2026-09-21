import SwiftUI
import ScoloCore

/// The source list, inside the sidebar panel.
///
/// The panel's surface, corner radius, border and inset belong to `MainWindow` —
/// this is what goes in it. The list no longer supplies its own background: the
/// panel is a solid colour, and a sidebar material inside a solid panel would be
/// two surfaces claiming the same rectangle.
///
/// `headerBand` is the height of the window's header, which this leaves empty at
/// the top. The panel's surface runs up behind the traffic lights, and the rows
/// start below them.
struct SidebarView: View {
    @Bindable var model: AppModel
    var headerBand: CGFloat = 0

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
        VStack(spacing: 0) {
            // The band the traffic lights sit in, and the collapse control with
            // them. The panel's colour is behind both; its rows are not. The
            // control itself belongs to the window — it has to outlive this panel
            // to travel when the panel goes away — so this only leaves it room.
            Color.clear.frame(height: headerBand)

            list
        }
        .onChange(of: model.view) { pendingView = nil }
        .safeAreaInset(edge: .bottom, spacing: 0) { capacityFooter }
    }

    private var list: some View {
        List {
            ForEach(AppModel.View.sidebarSections) { section in
                Section(section.title) {
                    ForEach(section.views) { view in
                        Button {
                            select(view)
                        } label: {
                            Label {
                                HStack {
                                    Text(view.title)
                                        // Neutral, not accent. A selected row is
                                        // marked by its fill and by the weight of
                                        // its label; turning the whole label blue
                                        // said "chosen" a second time, louder.
                                        .font(.system(size: 13,
                                                      weight: isSelected(view) ? .medium : .regular))
                                        .foregroundStyle(Token.Text.primary)
                                    Spacer()
                                    if let count = count(for: view) {
                                        Text(count, format: .number)
                                            .font(.mcSidebarCount)
                                            .foregroundStyle(Token.Text.tertiary)
                                    }
                                }
                            } icon: {
                                Image(systemName: view.symbol)
                                    // 18pt in the expanded sidebar. The scale is
                                    // pinned because a sidebar list sets one through
                                    // the environment and it multiplies whatever the
                                    // font says.
                                    .font(.system(size: 18, weight: .regular))
                                    .imageScale(.medium)
                                    .frame(width: 22, alignment: .leading)
                                    // Outline at rest, solid when chosen: the filled
                                    // glyph is most of what makes a selected row read
                                    // brighter, and it does it without colour.
                                    .symbolVariant(isSelected(view) ? .fill : .none)
                                    .foregroundStyle(Token.Text.primary)
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
                        .frame(height: Token.Size.sidebarRow)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            // Inset from the panel's edge, so the pill floats inside
                            // it instead of running edge to edge.
                            RoundedRectangle(cornerRadius: Token.Radius.sidebarRow,
                                             style: .continuous)
                                .fill(isSelected(view) ? Token.Fill.sidebarSelection : .clear)
                                .padding(.horizontal, Token.Size.sidebarRowInset)
                        )
                        .accessibilityAddTraits(isSelected(view) ? .isSelected : [])
                    }
                }
            }
            // No "Locations" section. It held one row, the startup volume, which
            // went nowhere: a label for the scope of every scan, dressed as a place
            // in a source list, where a row is a promise that pressing it does
            // something — and that a second disk could be picked, which no scan
            // offers. The footer below still names the volume beside its free space.
        }
        .listStyle(.sidebar)
        // The panel is already a surface. A sidebar list's own material inside it
        // would be two surfaces claiming one rectangle.
        .scrollContentBackground(.hidden)
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
    ///
    /// A card rather than a rule and a line: the sidebar's rows are the app's
    /// navigation and this is not one of them, so it is separated by being a
    /// surface of its own rather than by a divider that reads as one more group
    /// header. Three lines, in the order the question is asked — which disk, how
    /// much is left, how full it is.
    private var capacityFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No volume name. Scolo measures the startup disk and nothing else,
            // so naming it answered a question with one possible answer — and it
            // was taking the line that the figure someone opens this app for
            // should have to itself.
            Text(model.volume.map { "\(ByteFormatting.string($0.freeBytes)) free" } ?? "—")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)

            capacityBar

            Text(usedSummary ?? "—")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.quaternary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.box)
                .fill(Token.Fill.box)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// The fullness bar. Drawn by hand rather than with `ProgressView`, which paints
    /// the accent colour: the accent means "the thing you chose" everywhere else in
    /// this window, and how full a disk is was not chosen. A neutral ink says the
    /// same proportion without claiming it is a status.
    private var capacityBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Token.Fill.well)
                Capsule()
                    .fill(Token.ink(light: 0.55, dark: 0.85))
                    // A disk with a sliver used still shows a sliver, rather than
                    // rounding down to an empty track that says the wrong thing.
                    .frame(width: max(usedFraction > 0 ? Token.Size.sidebarCapacityBar : 0,
                                      geometry.size.width * usedFraction))
            }
        }
        .frame(height: Token.Size.sidebarCapacityBar)
    }

    private var usedFraction: Double {
        guard let volume = model.volume, volume.capacityBytes > 0 else { return 0 }
        return Double(volume.usedBytes) / Double(volume.capacityBytes)
    }

    /// "220.36 of 245.11 GB used". The unit is written once when both figures land
    /// in it, which on any real startup volume they do; a pair that somehow split
    /// units keeps both, since dropping one would then be a lie about the smaller.
    private var usedSummary: String? {
        guard let volume = model.volume else { return nil }
        let used = ByteFormatting.string(volume.usedBytes)
        let capacity = ByteFormatting.string(volume.capacityBytes)
        guard let usedUnit = used.split(separator: " ").last,
              let capacityUnit = capacity.split(separator: " ").last,
              usedUnit == capacityUnit
        else { return "\(used) of \(capacity) used" }
        return "\(used.dropLast(usedUnit.count + 1)) of \(capacity) used"
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
