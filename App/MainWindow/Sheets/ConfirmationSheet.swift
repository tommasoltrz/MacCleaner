import SwiftUI
import MacCleanerCore

/// The clean-up, empty-trash and photo-deletion confirmations.
///
/// One shell, three variants. Presented with `.sheet`, so macOS supplies the
/// attachment below the titlebar, the entrance animation, and Escape/Return
/// handling — all of which the HTML prototype had to fake.
struct ConfirmationSheet: View {

    enum Variant {
        case cleanUp(itemCount: Int, totalBytes: Int64)
        case emptyTrash(itemCount: Int, totalBytes: Int64)
        /// No byte count: `PHAssetResource` exposes no public size, so the sheet
        /// says how many photographs go and stays silent about megabytes rather
        /// than inventing a figure.
        case deletePhotos(count: Int)
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

            if showsReceipt {
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
                    .tint(isDestructive ? Token.color(.red) : Color.accentColor)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 404)
    }

    // MARK: - Variant copy

    /// Only the Trash keeps a receipt; a deleted photo is recovered in Photos'
    /// own Recently Deleted, which this app has no hand in.
    private var showsReceipt: Bool {
        if case .cleanUp = variant { return true }
        return false
    }

    /// Deleting photos is recoverable for 30 days, but it still reaches every device
    /// on the library — including a phone the user is not looking at — so it carries
    /// the destructive tint rather than the neutral one.
    private var isDestructive: Bool {
        switch variant {
        case .cleanUp: false
        case .emptyTrash, .deletePhotos: true
        }
    }

    private var title: String {
        switch variant {
        case .cleanUp(let count, _):
            let noun = count == 1 ? "item" : "items"
            return "Move \(count) \(noun) to the Trash?"
        case .emptyTrash(let count, _):
            return "Permanently erase the \(count) items in the Trash?"
        case .deletePhotos(let count):
            let noun = count == 1 ? "photo" : "photos"
            return "Delete \(count) \(noun) from every device?"
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
        case .deletePhotos:
            // Every clause here is something the user would otherwise discover
            // afterwards: that this is not a local action, and that their iCloud
            // storage will not move until they finish the job in Photos.
            return "These move to Recently Deleted in Photos and disappear from your "
                + "iPhone and every other device on this iCloud library. They stay "
                + "recoverable for 30 days, and iCloud storage is not freed until you "
                + "empty Recently Deleted in Photos yourself."
        }
    }

    private var confirmLabel: String {
        switch variant {
        case .cleanUp:      "Move to Trash"
        case .emptyTrash:   "Erase"
        case .deletePhotos: "Delete Everywhere"
        }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: Token.Radius.box, style: .continuous)
            .fill(Token.Fill.control)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    // The readable red rather than `systemRed`, which is a fill colour
                    // and washes out against the light tile behind it.
                    .foregroundStyle(isDestructive ? Token.textColor(.red) : Token.Text.primary)
            )
    }

    private var iconName: String {
        if case .deletePhotos = variant { return "photo.badge.minus" }
        return "trash"
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

#Preview("Delete photos") {
    ConfirmationSheet(
        variant: .deletePhotos(count: 128),
        keepReceipt: .constant(false),
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
