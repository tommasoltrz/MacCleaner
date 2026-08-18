import SwiftUI

/// The bar across the bottom of every view — tier-3 glass in the design.
///
/// Rendered through `safeAreaInset` rather than stacked above the content, so the
/// scroll view genuinely passes beneath it and the material blurs live. Stacking it
/// would produce a flat strip that merely looks translucent.
struct StatusBarView<Trailing: View>: View {
    let message: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(message)
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(height: Token.Size.statusBar)
        }
        .background(.bar)
    }
}

#Preview {
    StatusBarView(message: "Last clean-up 16 Aug at 9:41 AM — 4.2 GB reclaimed") {
        Button("Scan for Junk") {}
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }
    .frame(width: 900)
}
