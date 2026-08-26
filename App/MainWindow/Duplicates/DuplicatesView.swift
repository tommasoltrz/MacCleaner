import SwiftUI

/// Shows exact file duplicates and similar photos in one review area.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.duplicateKind {
        case .files:
            FileDuplicatesView(model: model)
        case .photos:
            PhotoDuplicatesView(model: model)
        }
    }
}
