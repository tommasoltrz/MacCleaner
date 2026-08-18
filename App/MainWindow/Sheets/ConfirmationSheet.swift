import SwiftUI
import MacCleanerCore

/// The clean-up and empty-trash confirmations.
///
/// One shell, two variants. Presented with `.sheet`, so macOS supplies the
/// attachment below the titlebar, the entrance animation, and Escape/Return
/// handling — all of which the HTML prototype had to fake.
struct ConfirmationSheet: View {

    enum Variant {
        case cleanUp(itemCount: Int, totalBytes: Int64)
        case emptyTrash(itemCount: Int, totalBytes: Int64)
    }

    let variant: Variant
    /// Whether to keep a removal-log receipt. Ignored by the erase variant, which
    /// cannot be undone by definition.
    @Binding var keepReceipt: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                iconTile

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Token.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(message)
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isReversible {
                receiptRow.padding(.top, 16)
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    // The design's own note: the prototype reused one label for both
                    // variants and it was wrong for the destructive one. Erasing is
                    // not "moving", and it gets the destructive tint.
                    .tint(isReversible ? Color.accentColor : Token.color(.red))
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 404)
    }

    // MARK: - Variant copy

    private var isReversible: Bool {
        if case .cleanUp = variant { return true }
        return false
    }

    private var title: String {
        switch variant {
        case .cleanUp(let count, _):
            let noun = count == 1 ? "item" : "items"
            return "Move \(count) \(noun) to the Trash?"
        case .emptyTrash(let count, _):
            return "Permanently erase the \(count) items in the Trash?"
        }
    }

    private var message: String {
        switch variant {
        case .cleanUp(_, let bytes):
            return "\(ByteFormatting.string(bytes)) will be moved to the Trash. "
                + "Nothing is erased until you empty it, and every path is written to the removal log."
        case .emptyTrash(_, let bytes):
            return "This erases \(ByteFormatting.string(bytes)) immediately. "
                + "Items already in the Trash cannot be put back afterwards."
        }
    }

    private var confirmLabel: String {
        isReversible ? "Move to Trash" : "Erase"
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: Token.Radius.box, style: .continuous)
            .fill(Token.Fill.control)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(isReversible ? Token.Text.primary : Token.color(.red))
            )
    }

    private var receiptRow: some View {
        Well {
            Toggle(isOn: $keepReceipt) {
                Text("Keep a Trash receipt so this can be undone for 30 days")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.primary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Clean up") {
    ConfirmationSheet(
        variant: .cleanUp(itemCount: 4, totalBytes: 4_512_000_000),
        keepReceipt: .constant(true),
        onConfirm: {}, onCancel: {}
    )
}

#Preview("Empty Trash") {
    ConfirmationSheet(
        variant: .emptyTrash(itemCount: 214, totalBytes: 9_040_000_000),
        keepReceipt: .constant(false),
        onConfirm: {}, onCancel: {}
    )
}
