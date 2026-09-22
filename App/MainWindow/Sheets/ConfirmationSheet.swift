import SwiftUI
import ScoloCore

/// Confirms permanent erasure or cleanup that needs user review.
struct ConfirmationSheet: View {

    enum Variant {
        /// A clean-up always moves to the Trash. There was a `permanentCount` here,
        /// for a preference that let the Scanner delete outright; it took a title, a
        /// message, a tint, a button label and the receipt row with it. The
        /// preference is gone — 20 Sep 2026 — and so is every branch it needed.
        case cleanUp(
            itemCount: Int,
            totalBytes: Int64,
            protectedDataCount: Int,
            /// What the disk would actually give back, once measured. `nil` while
            /// the reading is still running or when the filesystem declined it, and
            /// the copy then makes no claim about freed space at all.
            saving: CleanupSaving?
        )
        case emptyTrash(itemCount: Int, totalBytes: Int64)

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
    /// Applications that are open right now and own something in this clean-up.
    ///
    /// Non-empty turns the sheet's one decision into two: quit them first, or go
    /// ahead under them. Removing a cache from under its owner frees the same
    /// bytes, and the owner may misbehave until it is relaunched — Chrome did, on
    /// 19 Sep 2026; see `FileEntry.inUseBy`. The sheet says so and offers to do the
    /// quitting, and leaves the choice where it belongs.
    var runningOwnerNames: [String] = []
    let onConfirm: () -> Void
    /// Quit `runningOwnerNames`, then run the same plan. Required for the
    /// quit-first button to appear at all.
    var onQuitAndConfirm: (() -> Void)? = nil
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

            if let runningOwnersNote {
                Label {
                    Text(runningOwnersNote)
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Token.textColor(.orange))
                }
                .padding(.top, 14)
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if let onQuitAndConfirm, !runningOwnerNames.isEmpty {
                    // Return goes to the quit-first button: the default action of a
                    // sheet should be the one that cannot leave an app half-working.
                    Button(confirmLabel, action: onConfirm)
                    Button("Quit and Clean", action: onQuitAndConfirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(isDestructive ? Token.color(.red) : Color.accentColor)
                } else {
                    Button(confirmLabel, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        // The design's own note: the prototype reused one label for
                        // both variants and it was wrong for the destructive one.
                        // Erasing is not "moving", and it gets the destructive tint.
                        .tint(isDestructive ? Token.color(.red) : Color.accentColor)
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 404)
        // The app's own panel colour rather than the sheet material AppKit would
        // draw, which is translucent and takes a wash of the desktop — the thing
        // every other surface here stopped doing. A dialog sits above the page,
        // so it takes the surface a step up from it, the one the sidebar uses.
        .presentationBackground(Token.chrome)
    }

    // MARK: - Variant copy

    /// What the sheet says about open applications, or nothing.
    ///
    /// It claims only what is known: the files are in use and the app *may*
    /// misbehave. Whether it will depends on what that process holds in memory,
    /// which nothing outside it can see.
    private var runningOwnersNote: String? {
        guard !runningOwnerNames.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: runningOwnerNames)
        let plural = runningOwnerNames.count > 1
        return "\(names) \(plural ? "are" : "is") open and using some of these files. "
            + "Removing them now frees the same space, but \(plural ? "those apps" : "it") "
            + "may misbehave until relaunched. \u{201C}Quit and Clean\u{201D} asks "
            + "\(plural ? "them" : "it") to quit first; nothing is removed unless "
            + "\(plural ? "they do" : "it does")."
    }

    private var isDestructive: Bool {
        switch variant {
        case .cleanUp(_, _, let protected, _): protected > 0
        case .emptyTrash: true
        }
    }

    private var title: String {
        switch variant {
        case .cleanUp(let count, _, let protected, _):
            let noun = count == 1 ? "item" : "items"
            if protected > 0 {
                return "Remove \(count) \(noun), including protected data?"
            }
            return "Move \(count) \(noun) to the Trash?"
        case .emptyTrash(let count, _):
            return "Permanently erase the \(count) items in the Trash?"

        }
    }

    private var message: String {
        switch variant {
        case .cleanUp(_, let bytes, let protected, let saving):
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
            return "\(ByteFormatting.string(bytes)) will be moved to the Trash. "
                + "Nothing is erased until you empty it."
                + sharing
                + warning
        case .emptyTrash(_, let bytes):
            return "This erases \(ByteFormatting.string(bytes)) immediately. "
                + "Items already in the Trash cannot be put back afterwards."

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
        case .cleanUp(_, _, let protected, _):
            return protected > 0 ? "Remove Anyway" : "Move to Trash"
        case .emptyTrash:   return "Erase"
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
        if case .cleanUp(_, _, let protected, _) = variant, protected > 0 {
            return "exclamationmark.triangle"
        }
        return "trash"
    }
}

#Preview("Clean up") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 4, totalBytes: 4_512_000_000,
            protectedDataCount: 0, saving: nil
        ),
        onConfirm: {}, onCancel: {}
    )
}

#Preview("Clean up — owners open") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 6, totalBytes: 14_210_000_000,
            protectedDataCount: 0, saving: nil
        ),
        runningOwnerNames: ["Google Chrome", "Xcode"],
        onConfirm: {}, onQuitAndConfirm: {}, onCancel: {}
    )
}

#Preview("Clean up — protected data") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 2, totalBytes: 2_400_000_000,
            protectedDataCount: 1, saving: nil
        ),
        onConfirm: {}, onCancel: {}
    )
}

/// The user's real case: a 1.05 GB folder copied from Downloads into Documents,
/// where both copies share every block and removing one frees nothing.
#Preview("Clean up — shares storage") {
    ConfirmationSheet(
        variant: .cleanUp(
            itemCount: 1, totalBytes: 1_108_205_568,
            protectedDataCount: 0,
            saving: .init(freedBytes: 0, isMinimum: false)
        ),
        onConfirm: {}, onCancel: {}
    )
}

#Preview("Empty Trash") {
    ConfirmationSheet(
        variant: .emptyTrash(itemCount: 214, totalBytes: 9_040_000_000),
        onConfirm: {}, onCancel: {}
    )
}
