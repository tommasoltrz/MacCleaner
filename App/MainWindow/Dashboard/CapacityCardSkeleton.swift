import SwiftUI

/// The capacity card while a measurement is running.
///
/// Same geometry as the real card, drawn in bones: eyebrow, hero figures, the
/// track, and a two-column legend. Keeping the shape stops the page from jumping
/// when the figures land, and the pulse says "working" without a spinner.
struct CapacityCardSkeleton: View {

    @State private var pulsing = false

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                bone(width: 210, height: 11)

                HStack(alignment: .bottom) {
                    bone(width: 220, height: 34)
                    Spacer(minLength: 12)
                    bone(width: 120, height: 26)
                }
                .padding(.top, 10)

                // The track, whole: single grey until the segments are known.
                Capsule()
                    .fill(Token.Fill.control)
                    .frame(height: Token.Size.capacityBar)
                    .padding(.top, 16)

                legendBones
                    .padding(.top, 16)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(pulsing ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityLabel("Measuring storage")
    }

    private var legendBones: some View {
        HStack(alignment: .top, spacing: 34) {
            legendColumn
            legendColumn
        }
    }

    private var legendColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: Token.Radius.dot)
                        .fill(Token.Fill.control)
                        .frame(width: 8, height: 8)
                    // Varied widths, so the bones read as text rather than stripes.
                    bone(width: 90 + CGFloat(row % 3) * 28, height: 10)
                    Spacer(minLength: 12)
                    bone(width: 52, height: 10)
                }
                .frame(minHeight: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bone(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Token.Fill.control)
            .frame(width: width, height: height)
    }
}

#Preview {
    CapacityCardSkeleton().frame(width: 900).padding()
}
