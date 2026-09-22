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
                CompletionMark()
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
        .operationPageLayout()
        .accessibilityElement(children: .contain)
    }
}

/// Shows a removal result without an additional dialog.
struct RemovalCompletionView: View {
    let title: String
    let detail: String
    var isSuccess = true
    var showsActions = true
    var canContinue = true
    let onContinue: () -> Void
    let onViewDashboard: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CompletionMark(isSuccess: isSuccess)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Token.Text.primary)
            Text(detail)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)
                .multilineTextAlignment(.center)
            if showsActions {
                HStack(spacing: 12) {
                    Button("Continue", action: onContinue)
                        .buttonStyle(PageActionButtonStyle(tint: .white, foreground: .black))
                        .disabled(!canContinue)
                    Button("View Dashboard", action: onViewDashboard)
                        .buttonStyle(PageActionButtonStyle())
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: showsActions ? 460 : 420)
        .operationPageLayout()
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
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
