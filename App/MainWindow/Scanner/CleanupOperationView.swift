import SwiftUI
import ScoloCore

/// Shows removal progress and keeps the result visible until the user continues.
struct CleanupOperationView: View {
    let itemCount: Int
    let totalBytes: Int64
    var isComplete = false
    var canScan = true
    var onScanAgain: () -> Void = {}
    var onViewDashboard: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            if isComplete {
                CleanupCompletionMark()
                    .padding(.bottom, 4)
            }
            Text(isComplete ? "Moved to Trash" : "Moving items to Trash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Token.Text.primary)
            Text("\(itemCount) \(itemCount == 1 ? "item" : "items") · \(ByteFormatting.string(totalBytes))")
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
            if isComplete {
                HStack(spacing: 12) {
                    Button(action: onScanAgain) {
                        Label("Scan Again", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PageActionButtonStyle(tint: .white, foreground: .black))
                    .disabled(!canScan)
                    Button(action: onViewDashboard) {
                        Text("View Dashboard")
                    }
                }
                .buttonStyle(PageActionButtonStyle())
                .controlSize(.large)
                .padding(.top, 8)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Token.Text.primary)
                    .accessibilityLabel("Moving items to Trash")
            }
        }
        .frame(maxWidth: 380)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct CleanupCompletionMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Token.color(.green).opacity(0.12))
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Token.textColor(.green).opacity(0.3), lineWidth: 1)
            CheckmarkStroke()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Token.textColor(.green), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(14)
        }
        .frame(width: 60, height: 60)
        .scaleEffect(drawn || reduceMotion ? 1 : 0.94)
        .opacity(drawn ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: drawn)
        .task {
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
            drawn = true
        }
        .accessibilityHidden(true)
    }
}

private struct CheckmarkStroke: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        }
    }
}

#Preview("Moving items") {
    CleanupOperationView(itemCount: 24, totalBytes: 4_620_000_000)
        .background(Token.shell)
        .frame(width: 760, height: 480)
}

#Preview("Cleanup complete") {
    CleanupOperationView(itemCount: 24, totalBytes: 4_620_000_000, isComplete: true)
        .background(Token.shell)
        .frame(width: 760, height: 480)
}
