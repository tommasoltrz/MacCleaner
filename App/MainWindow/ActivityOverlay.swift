import SwiftUI
import ScoloCore

/// The window while a removal runs.
///
/// Files are on the move and the button that started them shows a spinner — but a
/// spinner in a footer button is not something a first-time user knows to look for,
/// and a window that neither responds nor says why reads as frozen. So the whole
/// content area goes under a scrim with the operation named in the middle, the way
/// Finder names a copy in its progress window.
///
/// This replaces `.disabled` on the detail pane. The toolbar is attached to that
/// pane, so `.disabled` reached the toolbar items through the environment and the
/// Scan capsule lost its glass for the duration. The overlay sits inside the safe
/// area — below the toolbar, which stays exactly as it was — and blocks input by
/// being on top of everything rather than by disabling anything.
struct ActivityOverlay: View {
    let activity: AppModel.Activity

    var body: some View {
        ZStack {
            // A fade of the page, not a blackout: the content stays legible enough
            // to see what is being removed, and the same scrim reads right in
            // both appearances because it is the page's own colour.
            Token.pageBackground.opacity(0.72)

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(activity.title)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                Text(activity.detail)
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(width: 340)
            // The box tint alone is 4.5 % white in dark, which vanishes over the
            // scrim; an opaque page-coloured backing under it makes a card.
            .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.card))
            .background(Token.pageBackground, in: RoundedRectangle(cornerRadius: Token.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.card)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
            )
            .shadow(color: Token.chipShadow, radius: 18, y: 8)
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
        ActivityOverlay(activity: .cleaningUp(itemCount: 12, totalBytes: 3_400_000_000, permanentCount: 0))
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
