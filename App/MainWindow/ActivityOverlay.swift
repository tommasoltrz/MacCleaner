import SwiftUI
import ScoloCore

/// Blocks page input while a removal operation runs.
struct ActivityOverlay: View {
    let activity: AppModel.Activity

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
