import AppKit
import SwiftUI
import ScoloCore

/// Presents one floating preview without blocking the main window.
struct PhotoPreviewWindowPresenter: NSViewRepresentable {
    let item: PhotoDuplicatesModel.Preview?
    let model: PhotoDuplicatesModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(item: item, model: model, parent: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: PreviewPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var itemID: String?
        private var outsideClickMonitor: Any?
        private weak var model: PhotoDuplicatesModel?

        func update(item: PhotoDuplicatesModel.Preview?, model: PhotoDuplicatesModel, parent: NSWindow?) {
            self.model = model
            guard let item else { close(); return }
            guard let parent else { return }
            let identity = "\(item.groupID):\(item.id)"
            guard itemID != identity else { return }
            let content = AnyView(PhotoPreviewContent(
                item: item,
                model: model,
                thumbnails: model.thumbnails,
                onClose: { [weak self] in self?.dismiss() }
            ).id(identity))

            if let panel, let hostingView {
                hostingView.rootView = content
                panel.makeKeyAndOrderFront(nil)
            } else {
                let panel = PreviewPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.title = "Photo preview"
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.hidesOnDeactivate = true
                panel.isReleasedWhenClosed = false
                panel.isMovableByWindowBackground = true
                panel.contentMinSize = NSSize(width: 480, height: 400)
                panel.collectionBehavior = [.fullScreenAuxiliary]
                panel.appearance = parent.appearance
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    panel.standardWindowButton(button)?.isHidden = true
                }
                let hostingView = NSHostingView(rootView: content)
                panel.contentView = hostingView
                panel.delegate = self
                self.hostingView = hostingView
                self.panel = panel
                let bounds = parent.screen?.visibleFrame ?? parent.frame
                let x = min(max(parent.frame.midX - panel.frame.width / 2, bounds.minX), bounds.maxX - panel.frame.width)
                let y = min(max(parent.frame.midY - panel.frame.height / 2, bounds.minY), bounds.maxY - panel.frame.height)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                panel.makeKeyAndOrderFront(nil)
                installOutsideClickMonitor()
            }
            itemID = identity
        }

        private func installOutsideClickMonitor() {
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, event.window !== panel else { return }
                    self.dismiss()
                }
                return event
            }
        }

        private func dismiss() {
            model?.preview = nil
            close()
        }

        func windowWillClose(_ notification: Notification) {
            model?.preview = nil
            removeMonitor()
            panel = nil
            hostingView = nil
            itemID = nil
        }

        func close() {
            removeMonitor()
            panel?.delegate = nil
            panel?.close()
            panel = nil
            hostingView = nil
            itemID = nil
        }

        private func removeMonitor() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
        }
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows a photo in a movable preview window.
struct PhotoPreviewContent: View {
    let item: PhotoDuplicatesModel.Preview
    @Bindable var model: PhotoDuplicatesModel
    let thumbnails: PhotoThumbnailLoader
    let onClose: () -> Void

    @State private var shown: PhotoAsset

    init(
        item: PhotoDuplicatesModel.Preview,
        model: PhotoDuplicatesModel,
        thumbnails: PhotoThumbnailLoader,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.model = model
        self.thumbnails = thumbnails
        self.onClose = onClose
        _shown = State(initialValue: item.asset)
    }

    private var group: DuplicateGroup? { model.groups.first { $0.id == item.groupID } }

    private var isKeeper: Bool { shown.id == group?.keeper.id }
    private var isSelected: Bool { model.selection.contains(shown.id) }
    private var siblings: [PhotoAsset] { group?.assets ?? [shown] }

    var body: some View {
        VStack(spacing: 0) {
            header
            image
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Token.Fill.box)
        .ignoresSafeArea()
        .background(PhotoPreviewKeyboardHandler(onClose: onClose, onStep: step))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo preview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Token.Text.secondary)
            .background(Token.Fill.control, in: Circle())
            .accessibilityLabel("Close preview")
            .help("Close preview (Space or Escape)")

            if let date = shown.creationDate {
                Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
            } else {
                Text("Photo preview")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.primary)
            }
            if shown.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Token.textColor(.red))
                    .accessibilityLabel("Favorite")
            }

            Spacer(minLength: 12)
            if let index = siblings.firstIndex(where: { $0.id == shown.id }) {
                Text("\(index + 1) of \(siblings.count)")
                    .font(.mcSubtitle.monospacedDigit())
                    .foregroundStyle(Token.Text.secondary)
                navigationButton("Previous photo", symbol: "chevron.left", direction: -1)
                navigationButton("Next photo", symbol: "chevron.right", direction: 1)
            }
        }
        .padding(16)
        .background(WindowDragHandle())
    }

    private func navigationButton(_ title: String, symbol: String, direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: symbol)
                .frame(width: 12)
        }
        .buttonStyle(PageActionButtonStyle(compact: true))
        .disabled(siblings.count < 2)
        .accessibilityLabel(title)
        .help(title)
    }

    private var image: some View {
        ZStack {
            Token.pageBackground
            if let nsImage = thumbnails.preview(for: shown.id) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("Photo \(siblings.firstIndex(where: { $0.id == shown.id }).map { $0 + 1 } ?? 1)")
            }
            if thumbnails.isPreviewLoading(shown.id) {
                VStack(spacing: 8) {
                    if let fraction = thumbnails.downloadProgress[shown.id], fraction > 0 {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 160)
                        Text("Downloading from iCloud… \(Int(fraction * 100))%")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading full resolution…")
                    }
                }
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)
                .padding(14)
                .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.box))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: shown.id) { thumbnails.loadPreview(shown.id) }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label(
                    isKeeper ? "Keeping this photo" : (isSelected ? "Selected for deletion" : "Keeping this copy"),
                    systemImage: isKeeper ? "checkmark.circle.fill" : (isSelected ? "checkmark.circle" : "photo")
                )
                .font(.mcControlLabel)
                .foregroundStyle(isKeeper ? Token.textColor(.green) : (isSelected ? Token.textColor(.red) : Token.Text.secondary))
                .lineLimit(1)
                Spacer(minLength: 12)
                Text("\(shown.pixelWidth) × \(shown.pixelHeight)")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if !isKeeper {
                    Button("Keep This One") {
                        guard let group else { return }
                        model.keepInstead(groupID: group.id, assetID: shown.id)
                    }
                    .buttonStyle(PageActionButtonStyle())
                    Button(isSelected ? "Deselect" : "Select for Deletion") {
                        model.toggle(shown.id)
                    }
                    .buttonStyle(PageActionButtonStyle(tint: .white, foreground: .black))
                }
            }
            .frame(height: 38)
        }
        .padding(16)
    }

    /// Moves through copies in the current group and returns to the first copy at the end.
    private func step(_ delta: Int) {
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == shown.id })
        else { return }
        let next = (index + delta + siblings.count) % siblings.count
        shown = siblings[next]
    }
}

/// Handles preview keys before the file grid or a focused button consumes them.
private struct PhotoPreviewKeyboardHandler: NSViewRepresentable {
    let onClose: () -> Void
    let onStep: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.onStep = onStep
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onClose: (() -> Void)?
        var onStep: ((Int) -> Void)?
        private var monitor: Any?

        func install(in view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = view?.window,
                          event.window === window, window.attachedSheet == nil,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                    else { return false }
                    switch event.keyCode {
                    case 49, 53: self.onClose?()
                    case 123, 126: self.onStep?(-1)
                    case 124, 125: self.onStep?(1)
                    default: return false
                    }
                    return true
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
