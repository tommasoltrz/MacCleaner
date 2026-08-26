import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import MacCleanerCore

// MARK: - Value types

/// How often the app scans on its own. The design's segmented control, in its order.
enum ScanSchedule: String, CaseIterable, Identifiable, Sendable {
    case never, weekly, daily

    var id: String { rawValue }

    /// The Core policy's vocabulary. The display order here is the design's
    /// segmented control; the policy cares only about the interval.
    var cadence: AutomaticScanPolicy.Cadence {
        switch self {
        case .never:  .never
        case .weekly: .weekly
        case .daily:  .daily
        }
    }

    var displayName: String {
        switch self {
        case .never:  "Never"
        case .weekly: "Weekly"
        case .daily:  "Daily"
        }
    }
}

/// How recently a file must have been opened to be left alone.
/// The iCloud plan, which macOS exposes no API for.
///
/// `brctl quota` reports the free space exactly but never the size of the plan it is
/// free within, so the app infers it — correctly for any account less than half
/// empty, and wrongly for a large plan that is nearly full. This is the escape hatch
/// for the second case.
enum ICloudPlan: String, CaseIterable, Identifiable, Sendable {
    case automatic, gb5, gb50, gb200, tb2, tb6, tb12

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Detect automatically"
        case .gb5:       "5 GB"
        case .gb50:      "50 GB"
        case .gb200:     "200 GB"
        case .tb2:       "2 TB"
        case .tb6:       "6 TB"
        case .tb12:      "12 TB"
        }
    }

    /// Binary gigabytes, because that is what Apple's own figures turn out to be —
    /// a "200 GB" plan reports 200 GiB of quota.
    var bytes: Int64? {
        let gib: Int64 = 1024 * 1024 * 1024
        switch self {
        case .automatic: return nil
        case .gb5:       return 5 * gib
        case .gb50:      return 50 * gib
        case .gb200:     return 200 * gib
        case .tb2:       return 2048 * gib
        case .tb6:       return 6144 * gib
        case .tb12:      return 12288 * gib
        }
    }
}

enum ProtectWindow: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) days" }
}

/// One thing every scan skips: a folder and its whole subtree, or a filename glob.
struct ExclusionRule: Identifiable, Hashable, Codable, Sendable {

    enum Kind: String, Codable, Sendable { case folder, pattern }

    var id: UUID = UUID()
    var kind: Kind
    /// An absolute path for folder rules; a glob such as `*.sparsebundle` for patterns.
    var value: String
    /// Built-in rules the user cannot delete. Only used for the ones that protect
    /// credentials — a cleaner that can be talked into deleting keychains is a
    /// liability, and the design flags that rule `locked` for the same reason.
    var isLocked: Bool = false

    static func folder(_ url: URL) -> Self {
        // Standardised so `/Users/me/./Developer/` and `~/Developer` compare equal and
        // cannot be added twice.
        ExclusionRule(kind: .folder, value: url.standardizedFileURL.path(percentEncoded: false))
    }

    static func pattern(_ glob: String, isLocked: Bool = false) -> Self {
        ExclusionRule(kind: .pattern, value: glob, isLocked: isLocked)
    }

    /// Paths render tilde-abbreviated: the design's list reads `~/Developer`, not
    /// `/Users/me/Developer`, and the home prefix is noise in a narrow column.
    var displayValue: String {
        kind == .folder ? (value as NSString).abbreviatingWithTildeInPath : value
    }

    var symbol: String { kind == .folder ? "folder" : "doc" }

    /// The trailing qualifier in the design's list.
    ///
    /// Every folder rule excludes its subtree, so the note is shown on all of them
    /// rather than only the first: "does this cover what is inside?" is the question
    /// the row has to answer, and answering it on one row implies the others differ.
    var qualifier: String? {
        switch kind {
        case .folder:  "and everything inside"
        case .pattern: isLocked ? "pattern · locked" : "pattern"
        }
    }
}

// MARK: - Settings

/// The design's `settings` block, persisted in `UserDefaults`.
///
/// Persistence is per-property rather than one encoded blob: a stray value in a
/// preferences file should cost one setting, not all of them, and `defaults read` on
/// a support call is worth keeping legible.
@MainActor
@Observable
final class SettingsStore {

    // MARK: Defaults

    /// The design's defaults, in one place so `resetToDefaults()` and first launch
    /// cannot drift apart.
    enum Defaults {
        static let launchAtLogin = true
        static let showInMenuBar = true
        static let scanSchedule = ScanSchedule.weekly
        static let idleOnly = true
        static let warnBelowGB = 20
        static let trashFirst = true
        static let confirmBeforeCleanup = true
        static let protectRecentDays = ProtectWindow.month

        /// Two categories ship off, per the design.
        ///
        /// Hidden & System Data reaches into the Trash, iOS backups and Mail
        /// downloads — all of it personal, none of it something to start measuring
        /// without being asked. Docker needs Docker Desktop running, so on by default
        /// it would mostly render as an unavailable row.
        static func categoryEnabled(_ category: CategoryID) -> Bool {
            switch category {
            case .documentsAndFiles, .applications, .applicationLeftovers,
                    .systemCaches, .packageManagers, .xcode:
                true
            case .hiddenSystemData, .docker:
                false
            }
        }

        /// Two protective patterns ship enabled and locked.
        ///
        /// The design's other sample rules (`~/Developer`, a Docker container) are one
        /// user's choices and are not shipped. These two are not preferences so much as
        /// facts about what must never be touched: a sparse bundle is a mounted disk
        /// image or a Time Machine store whose apparent size is nothing like its
        /// contents, and a keychain holds every credential the user owns.
        static let exclusions: [ExclusionRule] = [
            .pattern("*.sparsebundle", isLocked: true),
            .pattern("*.keychain-db", isLocked: true)
        ]
    }

    /// The slider's range. 20 GB sits at the design's 34% of it.
    static let warnBelowRange: ClosedRange<Int> = 5...50

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults
    /// Previews and tests drive the store without touching the user's login items.
    @ObservationIgnored private let managesLoginItem: Bool
    @ObservationIgnored private var isSyncingLoginItem = false

    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let showInMenuBar = "settings.showInMenuBar"
        static let scanSchedule = "settings.scanSchedule"
        static let idleOnly = "settings.idleOnly"
        static let warnBelowGB = "settings.warnBelowGB"
        static let iCloudPlan = "settings.iCloudPlan"
        static let categoryEnabled = "settings.categoryEnabled"
        static let trashFirst = "settings.trashFirst"
        static let confirmBeforeCleanup = "settings.confirmBeforeCleanup"
        static let protectRecentDays = "settings.protectRecentDays"
        static let exclusions = "settings.exclusions"
    }

    // MARK: Startup

    /// Mirrors the login item rather than owning it — see `syncLoginItem`.
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            syncLoginItem()
        }
    }

    var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) }
    }

    // MARK: Scanning

    var scanSchedule: ScanSchedule {
        didSet { defaults.set(scanSchedule.rawValue, forKey: Key.scanSchedule) }
    }

    var idleOnly: Bool {
        didSet { defaults.set(idleOnly, forKey: Key.idleOnly) }
    }

    var warnBelowGB: Int {
        didSet { defaults.set(warnBelowGB, forKey: Key.warnBelowGB) }
    }

    // MARK: iCloud

    var iCloudPlan: ICloudPlan {
        didSet { defaults.set(iCloudPlan.rawValue, forKey: Key.iCloudPlan) }
    }

    // MARK: Categories

    private(set) var categoryEnabled: [CategoryID: Bool] {
        didSet {
            let encoded = Dictionary(
                uniqueKeysWithValues: categoryEnabled.map { ($0.key.rawValue, $0.value) }
            )
            defaults.set(encoded, forKey: Key.categoryEnabled)
        }
    }

    func isEnabled(_ category: CategoryID) -> Bool {
        categoryEnabled[category] ?? Defaults.categoryEnabled(category)
    }

    func setEnabled(_ isEnabled: Bool, for category: CategoryID) {
        categoryEnabled[category] = isEnabled
    }

    func enabledBinding(for category: CategoryID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isEnabled(category) ?? false },
            set: { [weak self] in self?.setEnabled($0, for: category) }
        )
    }

    // MARK: Removal behaviour

    var trashFirst: Bool {
        didSet { defaults.set(trashFirst, forKey: Key.trashFirst) }
    }

    var confirmBeforeCleanup: Bool {
        didSet { defaults.set(confirmBeforeCleanup, forKey: Key.confirmBeforeCleanup) }
    }

    // MARK: Exclusions

    var protectRecentDays: ProtectWindow {
        didSet { defaults.set(protectRecentDays.rawValue, forKey: Key.protectRecentDays) }
    }

    private(set) var exclusions: [ExclusionRule] {
        didSet {
            guard let data = try? JSONEncoder().encode(exclusions) else { return }
            defaults.set(data, forKey: Key.exclusions)
        }
    }

    /// The rules split the way `ScanContext` consumes them.
    var excludedFolderPaths: [String] {
        exclusions.filter { $0.kind == .folder }.map(\.value)
    }
    var excludedPatterns: [String] {
        exclusions.filter { $0.kind == .pattern }.map(\.value)
    }

    /// Adds folder rules, ignoring anything that is not a directory or is already
    /// covered. Returns whether anything was added, which is also the drop's answer to
    /// Finder — a drop that changed nothing should not animate as accepted.
    @discardableResult
    func addFolders(_ urls: [URL]) -> Bool {
        let existing = Set(exclusions.map(\.value))
        let added = urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(ExclusionRule.folder)
            .filter { !existing.contains($0.value) }

        guard !added.isEmpty else { return false }
        exclusions.append(contentsOf: added)
        return true
    }

    @discardableResult
    func addPattern(_ glob: String) -> Bool {
        let trimmed = glob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !exclusions.contains(where: { $0.value == trimmed }) else {
            return false
        }
        exclusions.append(.pattern(trimmed))
        return true
    }

    /// Locked rules survive: they are what stops a scan from proposing a keychain.
    func remove(ids: Set<ExclusionRule.ID>) {
        exclusions.removeAll { ids.contains($0.id) && !$0.isLocked }
    }

    func canRemove(ids: Set<ExclusionRule.ID>) -> Bool {
        exclusions.contains { ids.contains($0.id) && !$0.isLocked }
    }

    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard, managesLoginItem: Bool = true) {
        self.defaults = defaults
        self.managesLoginItem = managesLoginItem

        // `defaults.bool(forKey:)` answers `false` for a key that was never written,
        // which would silently turn every on-by-default switch off on first launch.
        // Every read below goes through `object(forKey:)` for that reason.
        func bool(_ key: String, or fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }

        // The login item is system state, not a preference: `SMAppService` is the
        // truth. On first launch the design's default is applied once (below); after
        // that the system's answer wins, so removing the item in System Settings turns
        // this switch off too rather than leaving it claiming otherwise.
        let isFirstLaunch = defaults.object(forKey: Key.launchAtLogin) == nil
        self.launchAtLogin = if isFirstLaunch {
            Defaults.launchAtLogin
        } else if managesLoginItem {
            LoginItem.isEnabled
        } else {
            bool(Key.launchAtLogin, or: Defaults.launchAtLogin)
        }

        self.showInMenuBar = bool(Key.showInMenuBar, or: Defaults.showInMenuBar)
        self.scanSchedule = (defaults.string(forKey: Key.scanSchedule)
            .flatMap(ScanSchedule.init(rawValue:))) ?? Defaults.scanSchedule
        self.idleOnly = bool(Key.idleOnly, or: Defaults.idleOnly)
        self.iCloudPlan = (defaults.string(forKey: Key.iCloudPlan)
            .flatMap(ICloudPlan.init(rawValue:))) ?? .automatic
        self.warnBelowGB = (defaults.object(forKey: Key.warnBelowGB) as? Int)
            .map { $0.clamped(to: Self.warnBelowRange) } ?? Defaults.warnBelowGB

        // Read one key at a time rather than casting the whole dictionary: a category
        // added in a later version has no stored value and must fall back to its
        // default, not to `false`.
        let storedCategories = defaults.dictionary(forKey: Key.categoryEnabled) ?? [:]
        self.categoryEnabled = Dictionary(
            uniqueKeysWithValues: CategoryID.allCases.map { category in
                let stored = storedCategories[category.rawValue] as? Bool
                return (category, stored ?? Defaults.categoryEnabled(category))
            }
        )

        self.trashFirst = bool(Key.trashFirst, or: Defaults.trashFirst)
        self.confirmBeforeCleanup = bool(Key.confirmBeforeCleanup, or: Defaults.confirmBeforeCleanup)
        self.protectRecentDays = (defaults.object(forKey: Key.protectRecentDays) as? Int)
            .flatMap(ProtectWindow.init(rawValue:)) ?? Defaults.protectRecentDays

        let storedExclusions = defaults.data(forKey: Key.exclusions)
            .flatMap { try? JSONDecoder().decode([ExclusionRule].self, from: $0) }
        self.exclusions = Self.restoringLockedRules(in: storedExclusions ?? Defaults.exclusions)

        if isFirstLaunch {
            syncLoginItem()
            // Record that the default has been applied. Without this the key stays
            // absent, every launch looks like the first, and a login item the user
            // later removed in System Settings would be silently put back.
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        } else if managesLoginItem, launchAtLogin {
            // Re-register on every launch, not just the first: the record points at
            // whichever copy registered it, and a person who ran a development build
            // and later installed the app proper wants login opening the installed
            // copy, which is the one they are running now.
            LoginItem.setEnabled(true)
        }
    }

    /// Everything back to the design's defaults. Touches no files: the Advanced pane's
    /// alert says as much, and this is what makes that true.
    func resetToDefaults() {
        launchAtLogin = Defaults.launchAtLogin
        showInMenuBar = Defaults.showInMenuBar
        scanSchedule = Defaults.scanSchedule
        idleOnly = Defaults.idleOnly
        warnBelowGB = Defaults.warnBelowGB
        iCloudPlan = .automatic
        categoryEnabled = Dictionary(
            uniqueKeysWithValues: CategoryID.allCases.map { ($0, Defaults.categoryEnabled($0)) }
        )
        trashFirst = Defaults.trashFirst
        confirmBeforeCleanup = Defaults.confirmBeforeCleanup
        protectRecentDays = Defaults.protectRecentDays
        exclusions = Defaults.exclusions
    }

    /// Applies the switch to the real login item, then corrects the switch if the
    /// system disagreed. Registration fails on an unsigned build and lands in
    /// `.requiresApproval` when the user has denied it in System Settings; a switch
    /// left on after either of those is telling the user something untrue.
    private func syncLoginItem() {
        guard managesLoginItem, !isSyncingLoginItem else { return }
        let achieved = LoginItem.setEnabled(launchAtLogin)
        guard achieved != launchAtLogin else { return }

        isSyncingLoginItem = true
        launchAtLogin = achieved
        defaults.set(achieved, forKey: Key.launchAtLogin)
        isSyncingLoginItem = false
    }

    /// A locked rule that was decoded from a file the user edited comes back locked,
    /// and a locked rule that has been deleted out of band comes back at all.
    private static func restoringLockedRules(in rules: [ExclusionRule]) -> [ExclusionRule] {
        var result = rules
        for builtIn in Defaults.exclusions where builtIn.isLocked {
            if let index = result.firstIndex(where: { $0.value == builtIn.value }) {
                result[index].isLocked = true
            } else {
                result.insert(builtIn, at: 0)
            }
        }
        return result
    }
}

// MARK: - Login item

/// The `Open at login` switch's other half.
enum LoginItem {

    @MainActor
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters, and reports the state actually reached — which is not
    /// always the one asked for.
    @MainActor
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Nothing to show the user here: the switch snapping back is the message.
            return isEnabled
        }
        return isEnabled
    }
}

// MARK: - Full Disk Access

/// Full Disk Access, probed rather than requested.
///
/// macOS offers no API for "am I granted Full Disk Access" — TCC only answers by
/// letting a read succeed or fail. The convention is to open a file that nothing
/// outside the grant can read; the TCC database itself is the usual choice because it
/// exists on every install and is never readable without it. No prompt is raised: this
/// path is not one TCC offers to ask about, it simply fails.
enum FullDiskAccess {

    private static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    static var isGranted: Bool {
        guard let handle = FileHandle(forReadingAtPath: probePath) else { return false }
        try? handle.close()
        return true
    }

    /// Opens System Settings on the Full Disk Access list. The pane cannot pre-select
    /// the app, so the user still has to find it — there is no API that does more.
    @MainActor
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Other Application Data Access

/// Opens the privacy list for access to protected files and folders.
/// macOS requests this permission when MacCleaner opens another app's container.
enum AppDataAccess {
    @MainActor
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// Not under `#if DEBUG`: the `#Preview` bodies that call this still compile in
// Release, so the helper must exist there too.
extension SettingsStore {
    /// A throwaway store for `#Preview`, on its own volatile domain so a preview can
    /// never write to the real preferences or touch the real login item.
    static func preview(_ configure: (SettingsStore) -> Void = { _ in }) -> SettingsStore {
        let suite = "com.tommasolaterza.MacCleaner.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults, managesLoginItem: false)
        configure(store)
        return store
    }
}
