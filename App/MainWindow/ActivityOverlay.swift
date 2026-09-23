import SwiftUI
import ScoloCore

/// Keeps one opaque surface between removal progress and its result.
struct RemovalOperationSurface: View {
    @Bindable var model: AppModel
    var fadesOnDismiss = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsActivity: Bool {
        model.operations.activity != nil && !(model.view == .scanner && model.operations.isCleaningUp)
    }

    private var isPresented: Bool {
        showsActivity || model.photoDuplicates.isDeleting || model.operations.removalCompletion?.destination == model.view
    }

    var body: some View {
        Group {
            if isPresented {
                ZStack {
                    Token.pageBackground
                    if showsActivity, let activity = model.operations.activity {
                        ActivityOverlay(activity: activity)
                            .transition(.opacity)
                    } else if model.photoDuplicates.isDeleting {
                        PageProgressView(title: "Deleting photos", detail: "Waiting for Photos to finish.")
                            .transition(.opacity)
                    } else if let completion = model.operations.removalCompletion, completion.destination == model.view {
                        RemovalCompletionView(
                            title: completion.title,
                            detail: completion.detail,
                            isSuccess: completion.isSuccess,
                            showsActions: !completion.dismissesAutomatically,
                            canContinue: !model.isBusyWithDisk && !model.uninstaller.library.isLoadingApplicationLeftovers,
                            onContinue: model.operations.dismissRemovalCompletion,
                            onViewDashboard: { model.view = .dashboard }
                        )
                        .id(completion.id)
                        .task(id: completion.id) {
                            await model.automaticallyDismissRemovalCompletion(completion.id)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.operations.removalCompletion?.id)
                .transition(fadesOnDismiss
                    ? .asymmetric(insertion: .identity, removal: .opacity)
                    : .identity)
            }
        }
        .animation(fadesOnDismiss && !reduceMotion ? .easeOut(duration: 0.24) : nil, value: isPresented)
    }
}

/// Blocks page input while a removal operation runs.
struct ActivityOverlay: View {
    let activity: OperationState.Activity

    var body: some View {
        ZStack {
            Token.pageBackground
            PageProgressView(title: activity.title, detail: activity.detail)
        }
        // The colour fill is what catches the clicks. Without a content shape the
        // ZStack would let a click on the transparent card margins fall through.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(activity.title)
    }
}

#Preview("Cleaning up") {
    ZStack {
        Token.pageBackground
        ActivityOverlay(activity: .cleaningUp(itemCount: 12, totalBytes: 3_400_000_000))
    }
    .frame(width: 760, height: 480)
    .preferredColorScheme(.dark)
}

#Preview("Emptying the Trash") {
    ZStack {
        Token.pageBackground
        ActivityOverlay(activity: .emptyingTrash(itemCount: 214, totalBytes: 9_040_000_000))
    }
    .frame(width: 760, height: 480)
}
