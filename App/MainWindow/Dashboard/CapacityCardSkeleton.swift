import SwiftUI

/// The capacity card while a measurement is running.
///
/// Same geometry as the real card, drawn in bones: eyebrow, hero figures, the
/// track, and a two-column legend. Keeping the shape stops the page from jumping
/// when the figures land, and the pulse says "working" without a spinner.
struct CapacityCardSkeleton: View {

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

                SkeletonTrack()
                    .padding(.top, 16)

                LegendBones()
                    .padding(.top, 16)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .skeletonPulse()
        .accessibilityLabel("Measuring storage")
    }

    private func bone(width: CGFloat, height: CGFloat) -> some View {
        SkeletonBone(width: width, height: height)
    }
}

/// The parts of the skeleton the capacity card borrows while a measurement runs
/// with the volume totals already known: the card stays real up top and drops to
/// bones only where the figures are actually missing.

/// The track, whole: single grey until the segments are known.
struct SkeletonTrack: View {
    var body: some View {
        Capsule()
            .fill(Token.Fill.control)
            .frame(height: Token.Size.capacityBar)
    }
}

struct LegendBones: View {
    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            column
            column
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: Token.Radius.dot)
                        .fill(Token.Fill.control)
                        .frame(width: 8, height: 8)
                    // Varied widths, so the bones read as text rather than stripes.
                    SkeletonBone(width: 90 + CGFloat(row % 3) * 28, height: 10)
                    Spacer(minLength: 12)
                    SkeletonBone(width: 52, height: 10)
                }
                .frame(minHeight: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SkeletonBone: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Token.Fill.control)
            .frame(width: width, height: height)
    }
}

/// The skeleton's "working" pulse, shared so partial bones breathe exactly like
/// the full skeleton does.
extension View {
    func skeletonPulse() -> some View { modifier(SkeletonPulse()) }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // A repeating animation transaction can capture the startup layout.
        // The timeline changes only opacity, so flexible bones keep their width.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            content.opacity(reduceMotion ? 0.8 : pulseOpacity(at: context.date))
        }
    }

    private func pulseOpacity(at date: Date) -> Double {
        let duration = 1.8
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        let triangle = abs(phase * 2 - 1)
        let eased = triangle * triangle * (3 - 2 * triangle)
        return 0.55 + 0.45 * eased
    }
}

#Preview {
    CapacityCardSkeleton().frame(width: 900).padding()
}
