import SwiftUI
import MacCleanerCore

/// Shows a read-only record of MacCleaner removal results.
struct CleanupHistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.isLoadingCleanupHistory && model.cleanupHistory == nil {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else {
                historyTable
            }
        }
        .task { await model.loadCleanupHistory() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.loadCleanupHistory() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Cleanup History")
                .mcEyebrowStyle()

            if let summary = model.cleanupHistory {
                Text(summaryText(summary))
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
            }

            Text("MacCleaner saves this history when you keep a Put Back receipt.")
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.quaternary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }

    private var historyTable: some View {
        Table(items) {
            TableColumn("Item") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.originalURL.deletingLastPathComponent().path)
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.originalURL.path)
            }
            .width(min: 220, ideal: 430)

            TableColumn("Result") { item in
                ResultLabel(state: item.state)
            }
            .width(min: 150, ideal: 180, max: 210)

            TableColumn("Date") { item in
                Text(
                    item.timestamp,
                    format: .dateTime.day().month(.abbreviated).year().hour().minute()
                )
                    .foregroundStyle(Token.Text.secondary)
            }
            .width(min: 130, ideal: 145, max: 165)

            TableColumn("Size") { item in
                Text(item.bytes > 0 ? ByteFormatting.string(item.bytes) : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 82, max: 96)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var loadingState: some View {
        VStack {
            ContentUnavailableView {
                Label("Reading cleanup history", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("MacCleaner is checking which receipts still match items in the Trash.")
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(.top, 36)
    }

    private var emptyState: some View {
        VStack {
            ContentUnavailableView {
                Label("No cleanup history", systemImage: "clock")
            } description: {
                Text("Keep a Put Back receipt during cleanup to record removed items and failures.")
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(.top, 36)
    }

    private var items: [CleanupHistoryItem] {
        model.cleanupHistory?.items ?? []
    }

    private func summaryText(_ summary: CleanupHistorySummary) -> String {
        var parts = [
            "\(summary.removedCount) \(summary.removedCount == 1 ? "item" : "items") removed",
            "Removed size \(ByteFormatting.string(summary.removedBytes))",
            "\(summary.availableInTrashCount) available in Trash",
        ]
        if summary.permanentlyRemovedCount > 0 {
            parts.append("\(summary.permanentlyRemovedCount) permanent")
        }
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) failed")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ResultLabel: View {
    let state: CleanupHistoryState

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(helpText)
    }

    private var title: String {
        switch state {
        case .availableInTrash: "Available in Trash"
        case .inTrash: "In Trash"
        case .restored: "Put Back"
        case .removedPermanently: "Removed permanently"
        case .noLongerInTrash: "No longer in Trash"
        case .failed: "Could not remove"
        }
    }

    private var symbol: String {
        switch state {
        case .availableInTrash: "trash"
        case .inTrash: "trash"
        case .restored: "checkmark.circle"
        case .removedPermanently: "trash.slash"
        case .noLongerInTrash: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch state {
        case .availableInTrash: Token.textColor(.green)
        case .failed: Token.textColor(.orange)
        case .restored: Token.Text.secondary
        case .inTrash, .removedPermanently, .noLongerInTrash: Token.Text.tertiary
        }
    }

    private var helpText: String {
        switch state {
        case .availableInTrash:
            "The receipt matches this item in the Trash. Use the Trash view to put it back."
        case .inTrash:
            "The Trash path exists, but the receipt cannot prove that it contains the same item."
        case .restored:
            "MacCleaner put this item back at its original location."
        case .removedPermanently:
            "This item did not move to the Trash, so it cannot be put back."
        case .noLongerInTrash:
            "This receipt no longer matches an item in the Trash."
        case .failed:
            "MacCleaner did not remove this item."
        }
    }
}
