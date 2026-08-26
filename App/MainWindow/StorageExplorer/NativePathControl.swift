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
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectPath(_:))
        control.url = url
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = url
        context.coordinator.onSelect = onSelect
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
