import ColorSync
import CoreGraphics
import Foundation

extension WallpaperDownloads {
    struct DesktopSelections {
        var configurations: [[String: Any]] = []
        var isComplete = true
        var fingerprint: [String: Any] = [:]
    }

    static func desktopSelections(at root: URL, index: [String: Any]) -> DesktopSelections {
        let home = root.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let preferences = home.appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
        guard let data = metadata(preferences, under: home),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let settings = plist as? [String: Any],
              let configuration = settings["SpacesDisplayConfiguration"] as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]], !monitors.isEmpty else {
            return DesktopSelections(isComplete: false)
        }
        let spaces = index["Spaces"] as? [String: Any] ?? [:]
        let displays = index["Displays"] as? [String: Any] ?? [:]
        let defaults = index["SystemDefault"] as? [String: Any] ?? [:]
        let global = index["AllSpacesAndDisplays"] as? [String: Any] ?? [:]
        var result = DesktopSelections()
        var topology: [[String: Any]] = []
        for monitor in monitors {
            // Collapsed Space records belong to disconnected displays.
            guard let desktops = monitor["Spaces"] as? [[String: Any]], !desktops.isEmpty else {
                if monitor["Collapsed Space"] == nil { result.isComplete = false }
                continue
            }
            guard var display = monitor["Display Identifier"] as? String else {
                result.isComplete = false
                continue
            }
            if display == "Main" {
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else {
                    result.isComplete = false
                    continue
                }
                display = CFUUIDCreateString(nil, uuid) as String
            }
            var ids: [String] = []
            for desktop in desktops {
                guard let id = desktop["uuid"] as? String else {
                    result.isComplete = false
                    continue
                }
                ids.append(id)
                let space = spaces[id] as? [String: Any] ?? [:]
                let overrides = space["Displays"] as? [String: Any] ?? [:]
                // Use current display and Desktop overrides. Saved settings for removed Desktops do not apply.
                var selected = defaults
                for layer in [displays[display] as? [String: Any], space["Default"] as? [String: Any],
                              overrides[display] as? [String: Any], global] {
                    if let layer { selected.merge(layer) { _, current in current } }
                }
                result.configurations.append(selected)
            }
            topology.append(["display": display, "spaces": ids])
        }
        if result.configurations.isEmpty { result.isComplete = false }
        result.fingerprint = ["monitors": topology]
        return result
    }
}
