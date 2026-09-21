import SwiftUI
import ScoloCore

// MARK: - Grouped box

/// The design's grouped box: a rounded, hairline-bordered container.
///
/// Deliberately not `GroupBox`. The stock control draws its own title area and
/// padding, which fights every layout here; the design's box is a plain surface.
struct GroupedBox<Content: View>: View {
    var radius: CGFloat = Token.Radius.box
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
            )
    }
}

/// A recessed well — expanded table bodies, callouts, the exclusion list.
struct Well<Content: View>: View {
    var radius: CGFloat = Token.Radius.well
    @ViewBuilder var content: Content

    var body: some View {
        content.background(Token.Fill.well, in: RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Small parts

/// The 9pt rounded square identifying a category, matching its capacity-bar segment.
struct CategoryDot: View {
    let color: ColorToken
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.dot)
            .fill(Token.color(color))
            .frame(width: size, height: size)
    }
}

struct Badge: View {
    enum Style { case neutral, safe }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.mcBadge)
            // The label is read, so it takes the readable green; the capsule behind it
            // is a fill and keeps the system one.
            .foregroundStyle(style == .safe ? Token.textColor(.green) : Token.Text.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                style == .safe
                    ? Token.color(.green).opacity(0.16)
                    : Token.Fill.control,
                in: Capsule()
            )
    }
}

// MARK: - Button styles

/// A sidebar row: the label, and nothing else.
///
/// `.buttonStyle(.plain)` fades its label while the mouse is held down. No Mac source
/// list does that — press a row in Finder and the only thing that moves is the
/// selection. The moving pill is the whole feedback here, so this style reads
/// `configuration.isPressed` nowhere.
///
/// The row's other half of the fix lives at the call site: the selection is made on
/// mouse *down*, because a `Button` alone acts on mouse up and the delay reads as lag.
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Secondary button — the design's gradient-filled control with a specular top edge.
struct SecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel)
            .foregroundStyle(Token.Text.primary)
            .padding(.horizontal, 12)
            .frame(height: Token.Size.control)
            .background(
                isHovering ? Token.Fill.controlHover : Token.Fill.control,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.Fill.controlBorder, lineWidth: Token.hairline)
            )
            // Pressing darkens in both appearances. In light that is the platform's
            // own pressed state; in dark it is the design's.
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = $0 }
    }
}

/// Destructive button — red at low alpha with a tinted label, per the design's
/// Empty Trash and Reset controls.
struct DestructiveButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel.weight(.medium))
            .foregroundStyle(Token.Text.destructive)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                Token.color(.red).opacity(isHovering ? 0.26 : 0.16),
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.color(.red).opacity(0.40), lineWidth: Token.hairline)
            )
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = $0 }
    }
}

/// A row in the menu bar popover, highlighted the way a real `NSMenu` item is: the
/// whole row fills with the system selection blue under the pointer and the label
/// turns white.
///
/// `.buttonStyle(.plain)` gave the popover no hover state at all — the only feedback
/// was the label fading on mouse-down, which no menu on this platform does. The fill
/// is painted for a press as well as a hover, since a click that lands without the
/// pointer having moved (keyboard-driven, or a very fast click) still deserves one.
///
/// Disabled is handled here rather than left to the style's default: the fill must not
/// follow the pointer over "Scan for Junk" while a scan is already running, and a
/// hover recorded before the button was disabled must not survive into that state.
struct MenuItemButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isHovering || configuration.isPressed)
        return configuration.label
            // 13 pt, the size AppKit draws a menu item at — not the app's 12 pt
            // control label, because this reads as a menu and not as a control.
            .font(.mcRowTitleRegular)
            .foregroundStyle(
                highlighted ? Token.Text.onHighlight
                    : (isEnabled ? Token.Text.primary : Token.Text.disabled)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                highlighted ? Token.Fill.menuHighlight : .clear,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            // The label alone is a narrow target; a menu row answers anywhere along
            // its width, so the shape the hover and the click use is the filled one.
            .contentShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .onHover { isHovering = isEnabled && $0 }
    }
}

// MARK: - Hover tip

/// The capacity bar's immediate tooltip, as a reusable chip. The native `.help()`
/// waits out a dwell delay and only fires on the key window; a bar the user is
/// already pointing at should answer at once.
struct HoverTip: View {
    var color: ColorToken?
    let primary: String
    var secondary: String?

    var body: some View {
        HStack(spacing: 7) {
            if let color { CategoryDot(color: color, size: 8) }
            Text(primary)
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
            if let secondary {
                Text(secondary)
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Token.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
        .shadow(color: Token.chipShadow, radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Find field

/// The search field a list's header carries, and the receiving end of Edit › Find.
///
/// In the page header and not `.searchable`: the toolbar's principal item is already
/// the scan readout, and the Uninstaller's field set the precedent of sitting beside
/// the list it narrows. `findRequest` is `AppModel.findRequest`; every change to it
/// takes the focus, so ⌘F works again after the user has clicked away. Escape clears
/// the query first and gives up the focus second, as a search field in Finder does.
struct FindField: View {
    @Binding var text: String
    let findRequest: Int
    var prompt = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onChange(of: findRequest) { isFocused = true }
            .onExitCommand {
                if text.isEmpty { isFocused = false } else { text = "" }
            }
    }
}

// MARK: - Sortable column header

/// A column label that sorts the list beneath it, Finder-style: click to adopt the
/// column, click again to flip direction. The arrow appears only on the active
/// column. Typography and casing come from the surrounding header row, so this
/// composes with each table's existing style.
struct SortableColumnHeader: View {
    let title: String
    let isActive: Bool
    let ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Reverse the sort order" : "Sort by \(title.lowercased())")
    }
}

// MARK: - Rows

/// Applies the design's hover fill to a list row.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 0
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? Token.Fill.rowHover : .clear,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 0) -> some View {
        modifier(HoverHighlight(radius: radius))
    }

    /// Uppercased, tracked, quaternary — eyebrows and column headers.
    func mcEyebrowStyle(tracking: CGFloat = 0.055 * 11) -> some View {
        self.font(.mcEyebrow)
            .tracking(tracking)
            .textCase(.uppercase)
            .foregroundStyle(Token.Text.quaternary)
    }
}


// MARK: - Page header

/// The strip directly under the toolbar, on every view that has one.
///
/// It exists because each view had grown its own. Side padding was 18 in the Trash
/// and History, 16 in the Uninstaller and 14 in the Storage Explorer, while the
/// rows under every one of them are inset by 14 — so a header's own title sat out
/// of line with what it described, and no two views agreed on where the page
/// begins. The Scanner's scrolled away with the list, which is a fourth answer.
///
/// Pinned, never scrolling: three views put their search field here and four put
/// their selection controls here, and a control that scrolls out of reach is worse
/// than one that costs a little room.
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.vertical, 10)
        // A minimum rather than a fixed height: the Trash's header carries figures
        // at hero weight and is allowed to be taller than a line of caption text.
        .frame(minHeight: Token.Size.pageHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() })
    }
}

extension View {
    /// The ordinary left-hand line of a page header: what this page is showing,
    /// in one line, in the quiet tone.
    func pageHeaderSummary() -> some View {
        font(.mcControlLabel)
            .foregroundStyle(Token.Text.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

extension View {
    /// The inset every toolbar button's label carries.
    ///
    /// Shared because Scan and Remove sit next to each other: one of them had it
    /// and the other did not, which made the pair differ in both width and height
    /// for no reason a reader could see.
    func toolbarButtonLabel() -> some View {
        padding(.vertical, 1).padding(.horizontal, 8)
    }
}

// MARK: - Window shell

/// Shows and hides the sidebar.
///
/// Two treatments, per the design: inside the expanded panel it is a bare glyph,
/// because the panel it sits on is already a surface and a second one around the
/// glyph would be a button drawn on a button. Once the sidebar is away the glyph is
/// alone on the shell with nothing to belong to, so it takes a circular fill to
/// become a control again.
struct SidebarToggleButton: View {
    @Binding var isExpanded: Bool
    let isCollapsed: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Token.Text.secondary)
                .frame(width: 28, height: 28)
                .background {
                    if isCollapsed {
                        Circle().fill(isHovering ? Token.Fill.controlHover : Token.Fill.control)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: Token.Radius.sidebarRow, style: .continuous)
                            .fill(Token.Fill.rowHover)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isExpanded ? "Hide Sidebar" : "Show Sidebar")
    }
}

/// Stops a region from dragging the window.
///
/// The window hides its title bar so the shell can run up behind the traffic
/// lights, and everything drawn in that strip inherits the title bar's drag
/// behaviour — including the sidebar panel, which reaches the top of the window.
/// Pressing the panel's empty space would move the window instead of doing nothing.
struct WindowDragDisabled: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Blocker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Blocker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// Centres the window's traffic lights in the header band.
///
/// They are laid out for the 28pt title bar this window does not draw, which puts
/// them across the sidebar panel's top-left corner — the panel is inset 8pt and its
/// radius is 14, so the close button lands on the curve. Centring them in the band
/// clears it and lines them up with the title and actions beside them.
///
/// Positioned in window coordinates and converted into whichever view AppKit has
/// made their parent, so this does not depend on the private view hierarchy being
/// shaped any particular way. Re-applied on resize, because AppKit lays them out
/// again each time.
struct TrafficLightAlignment: NSViewRepresentable {
    let bandHeight: CGFloat

    func makeNSView(context: Context) -> NSView { Aligner(bandHeight: bandHeight) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Aligner)?.align()
    }

    private final class Aligner: NSView {
        private let bandHeight: CGFloat
        private var observer: NSObjectProtocol?

        init(bandHeight: CGFloat) {
            self.bandHeight = bandHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        // No `deinit`: the observer is torn down when the view leaves its window,
        // which is the same moment and is main-actor isolated, where a deinit is
        // not — it cannot touch this property at all under strict concurrency.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.align() }
            }
            align()
        }

        func align() {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            // AppKit is y-up, so the band's centre is measured down from the top.
            let centreInWindow = window.frame.height - bandHeight / 2
            for button in buttons {
                guard let parent = button.superview else { continue }
                let centre = parent.convert(NSPoint(x: 0, y: centreInWindow), from: nil).y
                let target = centre - button.frame.height / 2
                guard abs(button.frame.origin.y - target) > 0.5 else { continue }
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: target))
            }
        }
    }
}
