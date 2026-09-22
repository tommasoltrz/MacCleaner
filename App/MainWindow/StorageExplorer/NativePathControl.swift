import AppKit
import SwiftUI

/// Wraps the native macOS path control for folder navigation.
struct NativePathControl: NSViewRepresentable {
    let url: URL
    let onSelect: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // It must not take key focus. A path control is clicked, never typed into,
        // so focus buys it nothing — and while it held first responder the table
        // below was inactive, which drew every selected row in the *inactive* grey
        // instead of the accent. A selection that means "this is what Remove will
        // take" was reading as a hover.
        control.refusesFirstResponder = true
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectPath(_:))
        control.url = url
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = url
        context.coordinator.onSelect = onSelect
    }

    /// Lets long paths shorten before they reach the folder totals.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPathControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: 26)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectPath(_ sender: NSPathControl) {
            guard let url = sender.clickedPathItem?.url else { return }
            onSelect(url)
        }
    }
}
