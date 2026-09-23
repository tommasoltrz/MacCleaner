import SwiftUI

/// Shows exact file duplicates and similar photos in one review area.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(DuplicateKind.allCases) { kind in
                    PageTabPill(
                        title: kind.title,
                        symbol: kind == .files ? "doc.on.doc" : "photo.on.rectangle",
                        isSelected: model.duplicateKind == kind
                    ) { model.duplicateKind = kind }
                }
                if (model.duplicateKind == .photos && model.photoDuplicates.unavailableReason == nil)
                    || (model.duplicateKind == .files && model.fileDuplicates.fileDuplicateResults != nil) {
                    Rectangle()
                        .fill(Token.Fill.controlBorder)
                        .frame(width: Token.hairline, height: 22)
                        .padding(.horizontal, 8)
                    if model.duplicateKind == .photos {
                        PhotoSimilarityPicker(model: model.photoDuplicates, isDisabled: model.isBusyWithDisk)
                    } else {
                        FileDuplicateMinimumPicker(model: model)
                    }
                }
                Spacer(minLength: 0)
                if model.duplicateKind == .files, model.fileDuplicates.fileDuplicateResults != nil {
                    Button("Choose Other Folders") { model.chooseFileDuplicateFolders() }
                        .buttonStyle(PageActionButtonStyle())
                        .disabled(model.isBusyWithDisk)
                }
            }
            .disabled(model.operations.activity != nil || model.photoDuplicates.isDeleting || model.operations.removalCompletion?.destination == .duplicates)
            .frame(minHeight: 38)
            .padding(Token.Size.pageGutter)
            Divider()
            Group {
                switch model.duplicateKind {
                case .files: FileDuplicatesView(model: model)
                case .photos: PhotoDuplicatesView(model: model)
                }
            }
            .allowsHitTesting(model.operations.removalCompletion?.destination != .duplicates)
            .accessibilityHidden(model.operations.removalCompletion?.destination == .duplicates)
            .overlay {
                RemovalOperationSurface(model: model, fadesOnDismiss: true)
            }
        }
    }
}
