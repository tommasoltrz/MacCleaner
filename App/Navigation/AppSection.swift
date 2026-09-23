import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, scanner, storageExplorer, uninstaller, history, trash, duplicates
    var id: String { rawValue }

    /// A named group of sidebar rows.
    struct SidebarSection: Identifiable {
        let title: String
        let views: [AppSection]
        var id: String { title }
    }

    /// Cleanup comes first. Tools and storage information follow it.
    static var sidebarSections: [SidebarSection] {
        [
            SidebarSection(title: "", views: [.scanner]),
            SidebarSection(title: "Tools", views: [.storageExplorer, .uninstaller, .duplicates]),
            SidebarSection(title: "Overview", views: [.dashboard, .history, .trash])
        ]
    }

    var title: String {
        switch self {
        case .dashboard:    "Dashboard"
        case .scanner:      "Cleanup"
        case .storageExplorer: "Storage Explorer"
        case .uninstaller:  "App Uninstaller"
        case .history:      "History"
        case .trash:        "Trash"
        case .duplicates:   "Duplicates"
        }
    }

    /// SF Symbols, per the design's icon table.
    var symbol: String {
        switch self {
        case .dashboard:    "gauge.with.needle"
        case .scanner:      "magnifyingglass.circle"
        case .storageExplorer: "externaldrive"
        case .uninstaller:  "xmark.app"
        case .history:      "clock"
        case .trash:        "trash"
        case .duplicates:   "square.on.square"
        }
    }

    /// Each sidebar symbol has a matching filled variant.
    var selectedSymbol: String { symbol + ".fill" }
}
