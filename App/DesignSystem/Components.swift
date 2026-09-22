import SwiftUI
import ScoloCore

/// Gives cards immediate feedback while the mouse button is held.
struct CardPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Token.Radius.card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Token.Text.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// Animates the removal action without delaying its disabled state.
struct HeaderRemovalButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .foregroundStyle(isEnabled ? Color.white : Token.Text.disabled)
            .background(isEnabled ? tint : Token.Fill.controlDisabled, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Keeps native checkbox behavior with colors that follow the current theme.
struct MonochromeCheckbox: NSViewRepresentable {
    var title: String
    var detail: String? = nil
    var state: NSControl.StateValue
    var isEnabled = true
    var showsTitle = true
    var isCompact = false
    var onChange: (Bool) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.cell = MonochromeCheckboxCell(textCell: "")
        button.setButtonType(.switch)
        button.allowsMixedState = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggle)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = showsTitle ? title : ""
        button.imagePosition = showsTitle ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(title)
        button.controlSize = isCompact ? .small : .regular
        button.font = .systemFont(ofSize: 14, weight: .medium)
        if showsTitle, let detail {
            let label = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            label.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            button.attributedTitle = label
            button.setAccessibilityLabel("\(title), \(detail)")
        }
        button.state = state
        button.isEnabled = isEnabled && environmentEnabled
        button.invalidateIntrinsicContentSize()
        button.needsDisplay = true
        context.coordinator.onChange = { onChange(state != .on) }
    }

    final class Coordinator: NSObject {
        var onChange: (() -> Void)?

        @objc func toggle(_ sender: NSButton) { onChange?() }
    }
}

private final class MonochromeCheckboxCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        let dark = controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let opposite: NSColor = dark ? .black : .white
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.75 : 1) : 0.35
        let side: CGFloat = controlSize == .small ? 12 : 15
        let box = NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                         width: side, height: side)
        let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if state == .off {
            ink.withAlphaComponent(0.06 * alpha).setFill()
            shape.fill()
            ink.withAlphaComponent(0.45 * alpha).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else {
            ink.withAlphaComponent(alpha).setFill()
            shape.fill()
            let mark = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: box.minX + side * x,
                        y: box.minY + side * (controlView.isFlipped ? y : 1 - y))
            }
            if state == .mixed {
                mark.move(to: point(0.25, 0.5))
                mark.line(to: point(0.75, 0.5))
            } else {
                mark.move(to: point(0.23, 0.51))
                mark.line(to: point(0.43, 0.72))
                mark.line(to: point(0.78, 0.28))
            }
            opposite.withAlphaComponent(alpha).setStroke()
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
        }
    }
}

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

/// A compact action for controls inside cards and rows.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel)
            .foregroundStyle(isEnabled ? Token.Text.primary : Token.Text.disabled)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(
                isEnabled ? (isHovering ? Token.Fill.controlHover : Token.Fill.control) : Token.Fill.controlDisabled,
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

/// Destructive button — red at low alpha with a tinted label, per the design's
/// Empty Trash and Reset controls.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel.weight(.medium))
            .foregroundStyle(isEnabled ? Token.Text.destructive : Token.Text.disabled)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                isEnabled ? Token.color(.red).opacity(isHovering ? 0.26 : 0.16) : Token.Fill.controlDisabled,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(isEnabled ? Token.color(.red).opacity(0.40) : .clear, lineWidth: Token.hairline)
            )
            .brightness(isEnabled && configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = isEnabled && $0 }
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
        // A card, not a material: it floats over the page, and every other
        // surface in the app is now a colour of its own rather than a wash of
        // whatever is behind the window.
        .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
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
        font(.system(size: 14, weight: .medium))
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
    }
}

// MARK: - Window shell

/// Shows and hides the sidebar.
///
/// **One control, not two.** It is positioned over the whole layout rather than
/// placed in the sidebar and again in the header, so it travels with the sidebar's
/// edge instead of being removed from one view and inserted into another. The
/// stock `NavigationSplitView` toggle has the same ownership, and it is what makes
/// the movement read as one thing moving.
///
/// **The circle is only for the collapsed state**, where the glyph is alone on the
/// shell with nothing to belong to. Expanded, it sits on the sidebar panel, which
/// is already a surface — a circle there would be a button drawn on a button. Hover
/// fills a circle either way.
///
/// `showsCollapsedChrome` is separate from `isCollapsed` because the circle must
/// not travel: see `MainWindow`, which adds it after the movement has finished and
/// takes it off before the return journey begins.
struct SidebarToggleButton: View {
    let isCollapsed: Bool
    let showsCollapsedChrome: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: Token.Size.sidebarToggleGlyph, weight: .medium))
                .foregroundStyle(Token.Text.secondary)
                .frame(width: Token.Size.sidebarToggle, height: Token.Size.sidebarToggle)
                .background {
                    if showsCollapsedChrome { Circle().fill(Token.chrome) }
                    if isHovering { Circle().fill(Token.Fill.controlHover) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(isCollapsed ? "Show Sidebar" : "Hide Sidebar")
        .accessibilityLabel(isCollapsed ? "Show Sidebar" : "Hide Sidebar")
    }
}

/// Configures the window's chrome: the traffic lights' geometry, and who may drag.
///
/// **The lights.** They are laid out for the 28pt title bar this window does not
/// draw, which puts them across the sidebar panel's rounded corner. A stock
/// unified toolbar puts the first light's centre at (26, 26) with a 23pt gap
/// between centres, so that is what this applies — the same public AppKit frames,
/// without adding a toolbar surface to get them. (Values and approach taken from
/// Paguro, the app this window's structure follows.)
///
/// AppKit lays the buttons out again after a resize and after entering or leaving
/// full screen, and it does so *after* those notifications, so each one re-applies
/// on the next turn of the run loop rather than immediately.
///
/// **Dragging.** With a hidden title bar the top strip of the window is a drag
/// band whatever is drawn there, and the sidebar panel reaches into it. A nested
/// view answering false to `mouseDownCanMoveWindow` does not help: a SwiftUI
/// `ScrollView` short-circuits AppKit's hit-testing and the nested view is never
/// consulted, so a press on the sidebar's list would still slide the window. The
/// window's own drag is therefore off, and `WindowDragHandle` hands it back to the
/// one place that should have it — the header band.
struct WindowChrome: NSViewRepresentable {
    let headerBand: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let band = headerBand
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.configure(window: window, headerBand: band)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class Coordinator {
        private weak var configured: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func configure(window: NSWindow, headerBand: CGFloat) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovable = false
            Self.placeTrafficLights(in: window, headerBand: headerBand)

            guard configured !== window else { return }
            configured = window
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ].map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak window] _ in
                    DispatchQueue.main.async {
                        guard let window else { return }
                        MainActor.assumeIsolated {
                            Self.placeTrafficLights(in: window, headerBand: headerBand)
                        }
                    }
                }
            }
        }

        private static func placeTrafficLights(in window: NSWindow, headerBand: CGFloat) {
            let firstCentreX: CGFloat = 26
            let centreGap: CGFloat = 23
            let centreY = headerBand / 2
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview
                else { continue }
                button.setFrameOrigin(NSPoint(
                    x: firstCentreX + CGFloat(index) * centreGap - button.frame.width / 2,
                    y: container.bounds.height - centreY - button.frame.height / 2
                ))
            }
        }
    }
}

/// A transparent strip that moves the window on click-drag, and zooms on a
/// double-click, the way a title bar does. The window's own drag is off — see
/// `WindowChrome` — so this is how it is given back, deliberately, to the header
/// band and to nothing else.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Uses the same action size and response across pages.
struct PageActionButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var compact = false
    var foreground: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PageActionSurface(
            tint: tint, compact: compact, isPressed: configuration.isPressed,
            foreground: foreground
        ))
    }
}

/// Gives buttons and menus the same size, colors, and hover response.
struct PageActionSurface: ViewModifier {
    var tint: Color? = nil
    var compact = false
    var isPressed = false
    var foreground: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .padding(.horizontal, compact ? 12 : 20)
            .frame(minHeight: compact ? 28 : 38)
            .foregroundStyle(isEnabled ? (foreground ?? (tint == nil ? Token.Text.primary : Color.white)) : Token.Text.disabled)
            .background(isEnabled ? (tint ?? (isHovering ? Token.Fill.controlHover : Token.Fill.control)) : Token.Fill.controlDisabled, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled && isPressed ? 0.8 : 1)
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
    }
}

/// A separate pill for each page filter or presentation.
struct PageTabPill: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    let isSelected: Bool
    var tint: Color = Token.textColor(.accent)
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
                if let detail {
                    Text(detail).monospacedDigit().opacity(isSelected ? 1 : 0.75)
                }
            }
            .font(.mcRowTitle)
            .foregroundStyle(isSelected ? tint : Token.Text.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(isSelected ? tint.opacity(0.12) : Token.Fill.control, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? tint.opacity(0.3) : Token.Fill.controlBorder,
                    lineWidth: Token.hairline
                )
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
    }
}

/// Keeps operation progress visible for one second. Cancellation ends the wait immediately.
struct OperationPresentationDuration: Sendable {
    private let deadline = ContinuousClock.now.advanced(by: .seconds(1))

    func wait() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { return }
        try await ContinuousClock().sleep(until: deadline)
    }
}

extension View {
    /// Places page states below the controls with equal spacing and horizontal centering.
    func pageStateLayout() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ScanActionBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Marks the start action so the Stop button can use the same position.
    func scanActionAnchor() -> some View {
        anchorPreference(key: ScanActionBounds.self, value: .bounds) { $0 }
    }
}

/// Measures the intro without showing it while the scan runs.
struct ScanProgressPage<Intro: View, Progress: View>: View {
    @ViewBuilder var intro: () -> Intro
    @ViewBuilder var progress: (CGFloat?) -> Progress

    var body: some View {
        intro()
            .hidden()
            .disabled(true)
            .accessibilityHidden(true)
            .overlayPreferenceValue(ScanActionBounds.self) { anchor in
                GeometryReader { geometry in
                    progress(anchor.map { geometry[$0].maxY })
                }
            }
    }
}

extension View {
    /// Keeps progress and results in one content area below the page controls.
    func operationPageLayout(actionBottom: CGFloat? = nil) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .frame(maxWidth: .infinity, minHeight: actionBottom ?? 320, alignment: .bottom)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Shows progress in the content area with an optional stop action.
struct PageProgressView: View {
    let title: String
    var detail: String? = nil
    var progress: Double? = nil
    var onStop: (() -> Void)? = nil
    var actionBottom: CGFloat? = nil

    var body: some View {
        content.operationPageLayout(actionBottom: actionBottom)
    }

    private var content: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Token.Text.primary)
            if let detail {
                Text(detail)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .multilineTextAlignment(.center)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Token.Text.primary)
                .accessibilityLabel(title)
            if let onStop {
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(PageActionButtonStyle())
            }
        }
        .frame(maxWidth: 380)
    }
}

/// Reveals results after work ends without replaying on page navigation.
private struct OperationResultAnimation: ViewModifier {
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isRunning || isVisible ? 1 : 0)
            .offset(y: isRunning || isVisible || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isVisible)
            .task(id: isRunning) {
                if isRunning { isVisible = false; return }
                guard !isVisible else { return }
                if !reduceMotion {
                    do { try await Task.sleep(for: .milliseconds(30)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                isVisible = true
            }
            .onDisappear { isVisible = true }
    }
}

extension View {
    func operationResultAnimation(isRunning: Bool) -> some View {
        modifier(OperationResultAnimation(isRunning: isRunning))
    }
}

/// Animates changing totals without moving the surrounding layout.
private struct AnimatedTotal<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}

extension View {
    func animatedTotal<Value: Equatable>(_ value: Value) -> some View {
        modifier(AnimatedTotal(value: value))
    }
}

/// Shows a completed scan with no matching items.
struct ScanCompletionView: View {
    let title: String
    var detail: String? = nil
    var animate = false

    var body: some View {
        VStack(spacing: 18) {
            CompletionMark(animate: animate)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Token.Text.primary)
            if let detail {
                Text(detail)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .operationPageLayout()
        .accessibilityElement(children: .contain)
    }
}

struct CompletionMark: View {
    var animate = true
    var isSuccess = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Token.color(isSuccess ? .green : .orange).opacity(0.12))
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Token.textColor(isSuccess ? .green : .orange).opacity(0.3), lineWidth: 1)
            if isSuccess {
                CheckmarkStroke()
                    .trim(from: 0, to: drawn || !animate ? 1 : 0)
                    .stroke(Token.textColor(.green), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(14)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Token.textColor(.orange))
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(drawn || !animate || reduceMotion ? 1 : 0.94)
        .opacity(drawn || !animate ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: drawn)
        .task(id: animate) {
            guard animate else { return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
            drawn = true
        }
        .accessibilityHidden(true)
    }
}

private struct CheckmarkStroke: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        }
    }
}
