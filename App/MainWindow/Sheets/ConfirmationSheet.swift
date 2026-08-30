import SwiftUI
import ScoloCore

/// The clean-up, empty-trash and photo-deletion confirmations.
///
/// One shell, three variants. Presented with `.sheet`, so macOS supplies the
/// attachment below the titlebar, the entrance animation, and Escape/Return
/// handling — all of which the HTML prototype had to fake.
struct ConfirmationSheet: View {

    enum Variant {
        /// `permanentCount` is how many of the items will be deleted outright —
        /// non-zero when "Always move to Trash" is off in Advanced. The copy, the
        /// tint and the receipt row all key off it: a permanent deletion presented
        /// with Trash language would promise an undo that does not exist.
        case cleanUp(
            itemCount: Int,
            totalBytes: Int64,
            permanentCount: Int,
            protectedDataCount: Int,
            /// What the disk would actually give back, once measured. `nil` while
            /// the reading is still running or when the filesystem declined it, and
            /// the copy then makes no claim about freed space at all.
            saving: CleanupSaving?
        )
        case emptyTrash(itemCount: Int, totalBytes: Int64)
        case uninstallApp(
            applicationName: String,
            itemCount: Int,
            totalBytes: Int64,
            protectedDataCount: Int,
            applicationOnly: Bool
        )
        case deleteDuplicateFiles(count: Int, totalBytes: Int64)
        case removeStorageItems(count: Int, totalBytes: Int64, cloudItemCount: Int)
        /// No byte count: `PHAssetResource` exposes no public size, so the sheet
        /// says how many photographs go and stays silent about megabytes rather
        /// than inventing a figure.
        case deletePhotos(count: Int)
    }

    /// The gap between what a selection occupies and what removing it frees.
    ///
    /// APFS shares blocks between distinct files — a Finder copy within one volume
    /// is a clone — so a selection can be large and cost the disk nothing. Measured
    /// on this Mac: a 1.05 GB folder copied from Downloads into Documents reported
    /// its full size in both places and zero private bytes in either.
    struct CleanupSaving: Equatable {
        /// Bytes no other file holds. A lower bound when ``isMinimum`` is set.
        let freedBytes: Int64
        /// The selection holds two or more members of one clone family, whose
        /// shared blocks belong privately to none of them. Removing them together
        /// frees more than the sum, so the figure is worded as a floor.
        let isMinimum: Bool
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
    /// own Recently Deleted, which this app has no hand in — and a wholly
    /// permanent clean-up has nothing a receipt could bring back.
    private var showsReceipt: Bool {
        if case .cleanUp(let count, _, let permanent, _, _) = variant { return permanent < count }
        if case .uninstallApp = variant { return true }
        if case .deleteDuplicateFiles = variant { return true }
        if case .removeStorageItems = variant { return true }
        return false
    }

    /// Deleting photos is recoverable for 30 days, but it still reaches every device
    /// on the library — including a phone the user is not looking at — so it carries
    /// the destructive tint rather than the neutral one.
    private var isDestructive: Bool {
        switch variant {
        case .cleanUp(_, _, let permanent, let protected, _): permanent > 0 || protected > 0
        case .emptyTrash, .deleteDuplicateFiles, .removeStorageItems,
             .deletePhotos, .uninstallApp: true
        }
    }

    private var title: String {
        switch variant {
        case .cleanUp(let count, _, let permanent, let protected, _):
            let noun = count == 1 ? "item" : "items"
            if protected > 0 {
                return "Remove \(count) \(noun), including protected data?"
            }
            if permanent == count {
                return "Permanently delete \(count) \(noun)?"
            }
            if permanent > 0 {
                return "Remove \(count) \(noun)?"
            }
            return "Move \(count) \(noun) to the Trash?"
        case .emptyTrash(let count, _):
            return "Permanently erase the \(count) items in the Trash?"
        case .uninstallApp(let name, _, _, let protected, _):
            return protected > 0
                ? "Uninstall \(name) and remove its protected data?"
                : "Uninstall \(name)?"
        case .deletePhotos(let count):
            let noun = count == 1 ? "photo" : "photos"
            return "Delete \(count) \(noun) from every device?"
        case .deleteDuplicateFiles(let count, _):
            let noun = count == 1 ? "file" : "files"
            return "Move \(count) duplicate \(noun) to the Trash?"
        case .removeStorageItems(let count, _, _):
            let noun = count == 1 ? "item" : "items"
            return "Move \(count) \(noun) to the Trash?"
        }
    }

    private var message: String {
        switch variant {
        case .cleanUp(let count, let bytes, let permanent, let protected, let saving):
            let warning: String
            if protected > 0 {
                let noun = protected == 1 ? "item" : "items"
                let pronoun = protected == 1 ? "it" : "them"
                warning = " This includes \(protected) protected user-data \(noun); "
                    + "removing \(pronoun) can sign you out and erase profiles, history, or settings."
            } else {
                warning = ""
            }
            let sharing = Self.sharedStorageClause(selected: bytes, saving: saving)
            if permanent == count {
                return "\(ByteFormatting.string(bytes)) will be deleted immediately — "
                    + "not moved to the Trash — because \u{201C}Always move to Trash\u{201D} "
                    + "is off in Advanced. This cannot be undone." + sharing + warning
            }
            if permanent > 0 {
                let noun = permanent == 1 ? "item is" : "items are"
                return "\(ByteFormatting.string(bytes)) will be removed. "
                    + "\(permanent) \(noun) deleted immediately. The other selected "
                    + "items move to the Trash." + sharing + warning
            }
            // The receipt line states what the checkbox below it is currently set
            // to do: promising a removal log while it is unchecked was a lie the
            // user could see through by unticking the box.
            return "\(ByteFormatting.string(bytes)) will be moved to the Trash. "
                + "Nothing is erased until you empty it. "
                + (keepReceipt
                    ? "Every path is written to the removal log."
                    : "No receipt will be kept, so Put Back will not be available here.")
                + sharing
                + warning
        case .emptyTrash(_, let bytes):
            return "This erases \(ByteFormatting.string(bytes)) immediately. "
                + "Items already in the Trash cannot be put back afterwards."
        case .uninstallApp(_, let count, let bytes, let protected, let applicationOnly):
            if applicationOnly {
                return "Only the application (\(ByteFormatting.string(bytes))) will move to the Trash. "
                    + "Related files will stay on disk."
            }
            let related = max(0, count - 1)
            let noun = related == 1 ? "related item" : "related items"
            var warning = ""
            if protected > 0 {
                let protectedNoun = protected == 1 ? "item" : "items"
                warning = " This includes \(protected) protected user-data \(protectedNoun); "
                    + "profiles, logins, history, or settings may be lost."
            }
            return "The application and \(related) \(noun) "
                + "(\(ByteFormatting.string(bytes))) will move to the Trash. "
                + "If the application cannot move, none of its related files will be touched."
                + warning
        case .deletePhotos:
            // Every clause here is something the user would otherwise discover
            // afterwards: that this is not a local action, and that their iCloud
            // storage will not move until they finish the job in Photos.
            return "These move to Recently Deleted in Photos and disappear from your "
                + "iPhone and every other device on this iCloud library. They stay "
                + "recoverable for 30 days, and iCloud storage is not freed until you "
                + "empty Recently Deleted in Photos yourself."
        case .deleteDuplicateFiles(_, let bytes):
            return "One verified copy from each set will remain. Up to "
                + "\(ByteFormatting.string(bytes)) is available because APFS clones can share "
                + "storage. The selected files will move to the Trash."
        case .removeStorageItems(_, let bytes, let cloudItemCount):
            let cloudWarning = cloudItemCount > 0
                ? " Moving an iCloud item to the Trash also removes it from iCloud and other devices."
                : ""
            return "The selected items currently use \(ByteFormatting.string(bytes)). "
                + "This amount is not a promise of recovered space because files can share storage. "
                + "Scolo will verify each item again."
                + cloudWarning
        }
    }

    /// The one sentence that separates what a selection *occupies* from what
    /// removing it *frees*.
    ///
    /// Silent in the ordinary case — the two figures agree for anything not sharing
    /// storage, and a sentence appearing on every clean-up would train the user to
    /// skip it. Silent too while the measurement is still running, and when the
    /// filesystem declined to answer: this sheet names a figure or says nothing.
    ///
    /// The threshold is a tenth of the selection and at least 16 MB, so a few
    /// cloned files inside a large cache do not raise it, and a small selection
    /// that frees nothing at all still does.
    static func sharedStorageClause(selected: Int64, saving: CleanupSaving?) -> String {
        guard let saving, selected > 0 else { return "" }
        let shared = selected - saving.freedBytes
        guard shared >= max(16 * 1_048_576, selected / 10) else { return "" }

        let amount = ByteFormatting.string(saving.freedBytes)
        // "Will get back", not "will be freed": these items may be going to the
        // Trash, where they keep holding their blocks until it is emptied. Both
        // sentences have to stay true under either disposition.
        guard saving.isMinimum else {
            return " Only about \(amount) of that is storage this Mac will get back — "
                + "the rest is shared with other copies still on this disk."
        }
        // The selection holds two or more members of one clone family. Their shared
        // blocks are private to neither, so the figure is a floor — and "only at
        // least 0 B" is not a sentence. The selection total is the safe thing to
        // rule out instead: when items share blocks with each other, their sizes
        // add up to more storage than exists, so the whole of it can never return.
        return " Some of these items share storage with each other and with copies "
            + "still on this disk, so this Mac will get back at least \(amount) of "
            + "that — never the whole \(ByteFormatting.string(selected))."
    }

    private var confirmLabel: String {
        switch variant {
        case .cleanUp(let count, _, let permanent, let protected, _):
            if protected > 0 { return "Remove Anyway" }
            if permanent == count { return "Delete" }
            return permanent > 0 ? "Remove" : "Move to Trash"
        case .emptyTrash:   return "Erase"
        case .uninstallApp: return "Uninstall"
        case .deletePhotos: return "Delete Everywhere"
        case .deleteDuplicateFiles: return "Move to Trash"
        case .removeStorageItems: return "Move to Trash"
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
        if case .deleteDuplicateFiles = variant { return "doc.on.doc" }
        if case .removeStorageItems = variant { return "trash" }
        if case .uninstallApp = variant { return "trash.square" }
        if case .cleanUp(_, _, _, let protected, _) = variant, protected > 0 {
            return "exclamationmark.triangle"
        }
        return "trash"
    }

    private var receiptRow: some View {
        Well {
            Toggle(isOn: $keepReceipt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep a Put Back receipt")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.primary)
                    Text(
                        "Records original locations for Scolo’s Put Back. "
                        + "It does not change what moves to the Trash."
                    )
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
        variant: .cleanUp(
            itemCount: 4, totalBytes: 4_512_000_000,
            permanentCount: 0, protectedDataCount: 0, saving: nil
        ),
        keepReceipt: .constant(true),
        onConfirm: {}, onCancel: {}
    )
}

#Preview("Clean up — permanent") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 4, totalBytes: 4_512_000_000,
            permanentCount: 4, protectedDataCount: 0, saving: nil
        ),
        keepReceipt: .constant(true),
        onConfirm: {}, onCancel: {}
    )
}

#Preview("Clean up — protected data") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 2, totalBytes: 2_400_000_000,
            permanentCount: 0, protectedDataCount: 1, saving: nil
        ),
        keepReceipt: .constant(true),
        onConfirm: {}, onCancel: {}
    )
}

/// The user's real case: a 1.05 GB folder copied from Downloads into Documents,
/// where both copies share every block and removing one frees nothing.
#Preview("Clean up — shares storage") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 1, totalBytes: 1_108_205_568,
            permanentCount: 0, protectedDataCount: 0,
            saving: .init(freedBytes: 0, isMinimum: false)
        ),
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
