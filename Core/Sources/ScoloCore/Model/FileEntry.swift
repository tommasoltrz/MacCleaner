import Foundation

/// One removable thing: a file, a folder, or an app bundle with its leftovers.
public struct FileEntry: Sendable, Equatable, Identifiable {

    /// A removal workflow that needs more checks than ordinary file cleanup.
    public enum RemovalAction: Sendable, Equatable {
        case orphanedApplication(bundleIdentifier: String)
    }

    public enum Kind: String, Sendable {
        case file, folder, appBundle, cache, archive, diskImage
        /// An `.app` found in the user's folders — an installer in Downloads, a copy
        /// on the Desktop. Not `appBundle`: that kind means an *installed*
        /// application and routes to the uninstaller, which reasons about running
        /// state, leftovers and Homebrew. A bundle lying in Downloads has none of
        /// that; it is a large file the user downloaded, and it is removed like one.
        case downloadedApp

        /// SF Symbol name, per the design's icon table.
        public var symbolName: String {
            switch self {
            case .file:          "doc"
            case .folder:        "folder"
            case .appBundle:     "app"
            case .downloadedApp: "app.dashed"
            case .cache:         "folder"
            case .archive:       "doc.zipper"
            case .diskImage:     "externaldrive"
            }
        }

        /// File-row icon tint: gray documents, teal folders, purple for anything
        /// regenerable.
        public var color: ColorToken {
            switch self {
            case .file, .archive: .gray
            case .folder:         .teal
            case .cache:          .purple
            case .appBundle:      .accent
            case .downloadedApp:  .gray
            case .diskImage:      .gray
            }
        }
    }

    /// The absolute path, except for a synthetic application-leftover group.
    public var id: String {
        switch removalAction {
        case .orphanedApplication(let identifier):
            "orphaned-application:\(identifier)"
        case nil:
            url.path
        }
    }

    public var url: URL
    public var displayName: String
    /// Tilde-abbreviated parent, e.g. `~/Downloads`.
    public var parentDisplay: String
    public var kind: Kind
    public var allocatedBytes: Int64
    /// `nil` renders as the orange **Never opened** — the design's strongest signal
    /// that something is safe to remove.
    public var lastOpened: Date?
    /// Regenerates on demand; shown as `· regenerable` after the path.
    public var isRegenerable: Bool
    /// Why this entry is listed for information but refused for removal.
    ///
    /// Protection is shown, never silent: hiding these rows hid the useful fact
    /// that a daily app had grown gigabytes. The reason is carried so the UI can
    /// say the true thing. "In use" on an app that was merely opened last week
    /// reads as a lie.
    public enum ProtectionReason: String, Sendable, Equatable {
        /// The app has a live process right now. Ground truth from NSWorkspace.
        case running
        /// Activity inside the user's protection window (Preferences › Exclusions).
        ///
        /// A badge and a tooltip, nothing more: the checkbox works, the row is
        /// never pre-selected and never counted as safe. This is the one reason
        /// that does not lock, because a date is not a judgement — the user knows
        /// whether the folder they built yesterday matters. See
        /// `ScanContext.protectRecentDays`.
        case recentUse
        /// Profiles, logins, history, documents. Locked by default; an interactive
        /// caller may authorize this exact row after a destructive warning.
        case userData
    }

    /// How to remove something this app cannot: the explanation of what it is and
    /// the exact terminal command that removes it.
    ///
    /// Exists for things like simulator runtimes, which are sealed read-only
    /// volumes: `rm` fails on every file inside them even as root, and only their
    /// owning tool (`simctl`) can take them away. Hiding them made a 29 GB
    /// consumer invisible; listing them with a working checkbox would be a lie the
    /// user discovers only after confirming. This is the honest third option.
    public struct ManualRemoval: Sendable, Equatable {
        public let explanation: String
        public let command: String

        public init(explanation: String, command: String) {
            self.explanation = explanation
            self.command = command
        }
    }

    public var manualRemoval: ManualRemoval?

    /// A specialized cleanup action for this row.
    public var removalAction: RemovalAction?

    public var protectionReason: ProtectionReason?
    /// Any reason at all: drives the badge, nothing else.
    public var isProtectedFromRemoval: Bool { protectionReason != nil }

    /// Whether removal is actually refused.
    ///
    /// Only two reasons lock by default: a running app (Finder refuses the same
    /// trash operation, and it would fail), and user data (which needs an explicit
    /// row-specific or app-uninstall authorization).
    /// Recent use is information, not a veto. The user, not a date heuristic,
    /// decides whether last week's download stays.
    public var isRemovalLocked: Bool {
        protectionReason == .running || protectionReason == .userData
            || manualRemoval != nil
    }
    /// Item count for folders, shown as `· 1,204 items`.
    public var childCount: Int?
    /// Files disclosed under this row. A selected parent removes these first.
    /// Protected app data still requires explicit uninstall authorization.
    public var children: [FileEntry]

    public init(
        url: URL,
        displayName: String? = nil,
        parentDisplay: String? = nil,
        kind: Kind,
        allocatedBytes: Int64,
        lastOpened: Date? = nil,
        isRegenerable: Bool = false,
        protectionReason: ProtectionReason? = nil,
        manualRemoval: ManualRemoval? = nil,
        removalAction: RemovalAction? = nil,
        childCount: Int? = nil,
        children: [FileEntry] = []
    ) {
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.parentDisplay = parentDisplay
            ?? FileEntry.abbreviate(url.deletingLastPathComponent().path)
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.lastOpened = lastOpened
        self.isRegenerable = isRegenerable
        self.protectionReason = protectionReason
        self.manualRemoval = manualRemoval
        self.removalAction = removalAction
        self.childCount = childCount
        self.children = children
    }

    /// Bytes freed by removing this entry and everything attached to it.
    public var totalBytesIncludingChildren: Int64 {
        allocatedBytes + children.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// What removal can actually offer. A protected entry contributes only its
    /// removable children; counting its own bytes would promise space the app
    /// refuses to free.
    public var reclaimableBytes: Int64 {
        if removalAction != nil {
            return children.reduce(0) { $0 + $1.allocatedBytes }
        }
        let childBytes = children
            .filter { !$0.isRemovalLocked }
            .reduce(Int64(0)) { $0 + $1.allocatedBytes }
        return isRemovalLocked ? childBytes : allocatedBytes + childBytes
    }

    /// The figure a row advertises, and the one every *display* total sums —
    /// category totals, tiles, list headers. `reclaimableBytes` answers a different
    /// question, "what would removal free", and belongs to cleanup arithmetic only.
    ///
    /// For an ordinary entry this is what removal frees. A manual-removal row
    /// frees nothing *through this app* — Docker's images, a sealed simulator
    /// runtime — but the space is real and the row states it, so the tile above the
    /// list and the list header have to agree with the rows. Summing
    /// `reclaimableBytes` instead made Docker's 5 GB appear as "0 B" over a list of
    /// gigabyte rows.
    public var displayBytes: Int64 {
        if removalAction != nil { return reclaimableBytes }
        return manualRemoval != nil ? totalBytesIncludingChildren : reclaimableBytes
    }

    /// Bytes among this row's children that regenerate and can actually be removed.
    ///
    /// Counted as safe wherever the row itself is not. An application's caches come
    /// back the next time it launches even though the application does not, and the
    /// Scanner has always said so by badging those children `regenerable`; without
    /// this the Dashboard's "Safe to remove" could not see them, because they are
    /// children rather than rows and their parent is never safe.
    public var regenerableChildBytes: Int64 {
        children
            .filter { $0.isRegenerable && !$0.isRemovalLocked }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    /// The size shown beside a top-level Scanner row. Applications show only their
    /// installed bundle. Other parents include their disclosed removal targets.
    public var rowDisplayBytes: Int64 {
        kind == .appBundle ? allocatedBytes : displayBytes
    }

    public var orphanedApplicationBundleIdentifier: String? {
        guard case .orphanedApplication(let identifier) = removalAction else { return nil }
        return identifier
    }

    /// `/Users/me/Downloads` → `~/Downloads`
    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The design's trailing qualifier: `· 1,204 items` or `· regenerable`.
    public var parentQualifier: String {
        if isRegenerable { return "\(parentDisplay) · regenerable" }
        if let childCount, childCount > 0 {
            let formatted = NumberFormatter.localizedString(
                from: NSNumber(value: childCount), number: .decimal
            )
            return "\(parentDisplay) · \(formatted) items"
        }
        return parentDisplay
    }
}
