import Foundation

enum DuplicateKind: String, CaseIterable, Identifiable {
    case files, photos
    var id: String { rawValue }

    var title: String {
        switch self {
        case .files:  "Files"
        case .photos: "Photos"
        }
    }
}
