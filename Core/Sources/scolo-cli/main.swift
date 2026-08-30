// AppKit here, and only here: the Core library stays free of it, but this harness
// must mirror the app's ownership oracle exactly, and "which applications are
// running right now" has no answer outside NSWorkspace.
import AppKit
import CoreServices
import Foundation
import ScoloCore

// Headless harness for the scanning engine. Every measurement the app makes can be
// exercised here without launching the UI, which is how each engine phase is
// verified against the real disk:
//
//     swift run scolo-cli volume
//     swift run scolo-cli snapshots
//     swift run scolo-cli measure <path>
//     swift run scolo-cli apps
//
// `snapshot` and `growth` write to and read from the same measurement history the
// app keeps. A snapshot taken here is tagged `cli`, so it is easy to see — and to
// delete — in `~/Library/Application Support/Scolo/storage-history/`.

@main
struct CLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "volume":
                try await volume()
            case "snapshots":
                try await snapshots()
            case "breakdown":
                try await breakdown()
            case "snapshot":
                try await snapshot()
            case "growth":
                try growth(baseline: arguments.dropFirst().first)
            case "scan":
                try await scan()
            case "apps":
                try await apps()
            case "measure":
                guard arguments.count > 1 else {
                    throw CLIError.usage("measure needs a path")
                }
                try await measure(path: arguments[1])
            case "reclaim":
                guard arguments.count > 1 else {
                    throw CLIError.usage("reclaim needs a path")
                }
                try await reclaim(path: arguments[1])
            default:
                print("scolo-cli — ScoloCore engine harness")
                print("commands: volume | snapshots | breakdown | snapshot"
                      + " | growth [previous|7d|cleanup] | scan | apps | measure <path>"
                      + " | reclaim <path>")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func volume() async throws {
        let service = DiskInfoService()
        let volume = try await service.volumeInfo()
        let dataUsed = try await service.dataVolumeUsedBytes()

        print(volume.eyebrow)
        print("  capacity      \(ByteFormatting.string(volume.capacityBytes))")
        print("  used          \(ByteFormatting.string(volume.usedBytes))")
        print("  free          \(ByteFormatting.string(volume.freeBytes))")
        print("  data volume   \(ByteFormatting.string(dataUsed))")
        // The firmlink check: this tree is invisible to anything walking `/`.
        let dataSystem = try await AllocatedSizeMeasurer()
            .measure(URL(fileURLWithPath: "/System/Volumes/Data/System"))
        print("  data-side /System \(ByteFormatting.string(dataSystem.allocatedBytes))"
              + "  (\(dataSystem.fileCount) files, \(dataSystem.unreadableCount) unreadable)")
    }

    /// Every application with its leftovers, one line each.
    ///
    /// `scan` prints category totals and the top three rows, which is the wrong
    /// shape for checking curation: the interesting part is the children, and
    /// specifically whether the locked entry and the cache entries add up to the
    /// folder they came from. This prints them, so the split can be read against
    /// `measure <path>` on the same folder.
    static func apps() async throws {
        let result = try await ApplicationsScanner().scan(context: ScanContext())
        for entry in result.entries where !entry.children.isEmpty {
            print("\(entry.displayName)  \(ByteFormatting.string(entry.totalBytesIncludingChildren))")
            for child in entry.children {
                let flag = child.isRemovalLocked ? "LOCKED" : (child.isRegenerable ? "cache " : "      ")
                print("    [\(flag)] \(ByteFormatting.string(child.allocatedBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) "
                      + "\(child.displayName)  (\(FileEntry.abbreviate(child.url.path)))"
                      + (child.childCount.map { " · \($0) items" } ?? ""))
            }
        }
    }

    static func scan() async throws {
        let started = Date()
        // The same ownership context the app builds, or the Application Leftovers
        // figures here describe a different product: without Launch Services this
        // harness once reported 26 orphaned groups and 9.8 GB where the app
        // offered 3 and 868 KB.
        let planner = OrphanedAppLeftoverPlanner()
        let candidates = planner.scanCandidates()
        // A running application owns its identifiers whether or not Launch
        // Services has registered it — a development build launched from Xcode,
        // for instance. The app counts these; leaving them out let such an app's
        // data show up as orphaned in this harness alone.
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let registered = OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates.identifiers,
            running: running,
            isInstalled: { identifier in
                guard let urls = LSCopyApplicationURLsForBundleIdentifier(
                    identifier as CFString, nil
                )?.takeRetainedValue() as? [URL] else { return false }
                return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
            }
        )
        let context = ScanContext(
            registeredApplicationBundleIdentifiers: registered,
            applicationLeftoverCandidates: candidates
        )
        let results = try await ScanCoordinator.standard().scan(
            context: context,
            onProgress: { print("  … \($0.percent)% (\($0.completedCategories)/\($0.totalCategories))") }
        )
        print("")

        for category in results.categories {
            let name = category.categoryID.displayName
                .padding(toLength: 24, withPad: " ", startingAt: 0)
            switch category.availability {
            case .available:
                print("  \(name) \(ByteFormatting.string(category.totalBytes).padding(toLength: 11, withPad: " ", startingAt: 0)) "
                      + "\(category.entries.count) items"
                      + (category.unreadableCount > 0 ? "  (\(category.unreadableCount) unreadable)" : ""))
                for entry in category.entries.prefix(3) {
                    let opened = entry.lastOpened.map { Self.relative($0) } ?? "Never opened"
                    // A leftover group carries its size in its children, as the app's
                    // table knows; printing `allocatedBytes` showed every group as 0 B.
                    print("      \(ByteFormatting.string(entry.removalAction == nil ? entry.allocatedBytes : entry.displayBytes).padding(toLength: 11, withPad: " ", startingAt: 0)) "
                          + "\(entry.displayName)  \(entry.parentQualifier)  · \(opened)")
                }
            case .empty:
                print("  \(name) —            (nothing found)")
            case .unavailable(let reason):
                print("  \(name) —            \(reason)")
            }
        }

        // Every byte must be offered by exactly one category. Overlapping roots would
        // make "Safe to remove" promise space the disk cannot give back twice.
        var owner: [String: CategoryID] = [:]
        var collisions: [(String, CategoryID, CategoryID)] = []
        for category in results.categories {
            for entry in category.entries {
                if let existing = owner[entry.id], existing != category.categoryID {
                    collisions.append((entry.id, existing, category.categoryID))
                } else {
                    owner[entry.id] = category.categoryID
                }
            }
        }

        print("")
        print("  total          \(ByteFormatting.string(results.totalBytes))")
        print("  safe to remove \(ByteFormatting.string(results.safeToRemoveBytes))")
        print("  needs review   \(ByteFormatting.string(results.needsReviewBytes))")
        print("  duplicates     \(collisions.isEmpty ? "none (categories are disjoint)" : "\(collisions.count) PATHS CLAIMED TWICE")")
        for (path, first, second) in collisions.prefix(5) {
            print("      \(path)  —  \(first.displayName) + \(second.displayName)")
        }
        print("  elapsed        \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func breakdown() async throws {
        let started = Date()
        let result = try await StorageBreakdownService().breakdown()
        let elapsed = Date().timeIntervalSince(started)

        print("capacity \(ByteFormatting.string(result.capacityBytes))"
              + "  used \(ByteFormatting.string(result.usedBytes))"
              + "  free \(ByteFormatting.string(result.freeBytes))")
        print("")
        for segment in result.segments {
            let percent = String(format: "%5.2f%%", result.percent(of: segment))
            let name = segment.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)
            print("  \(name) \(ByteFormatting.string(segment.bytes).padding(toLength: 11, withPad: " ", startingAt: 0)) \(percent)")
        }

        // The reconciliation that the whole design depends on.
        let total = result.segments.reduce(Int64(0)) { $0 + $1.bytes }
        let drift = result.capacityBytes - total
        print("")
        print("  segments sum   \(ByteFormatting.string(total))")
        print("  drift          \(drift) bytes  \(drift == 0 ? "(exact)" : "(MISMATCH)")")
        print("  unreadable     \(result.unreadableCount) entries")
        print("  elapsed        \(String(format: "%.1fs", elapsed))")
    }

    /// Measures the disk and stores the result in the app's measurement history.
    static func snapshot() async throws {
        let started = Date()
        let measurement = try await StorageBreakdownService().measure()
        let elapsed = Date().timeIntervalSince(started)

        let total = measurement.breakdown.segments.reduce(Int64(0)) { $0 + $1.bytes }
        let drift = measurement.breakdown.capacityBytes - total

        guard let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: .cli) else {
            print("  NOT STORED    the segments do not sum to capacity (drift \(drift) bytes)")
            return
        }
        let store = StorageSnapshotStore()
        try store.save(snapshot)

        print("stored \(store.fileURL(for: snapshot).lastPathComponent)")
        print("  used           \(ByteFormatting.string(snapshot.usedBytes))")
        print("  nodes          \(snapshot.nodes.count) folders at or above "
              + "\(ByteFormatting.string(snapshot.contract.minimumNodeBytes)) "
              + "(depth \(snapshot.contract.nodeDepth))")
        print("  drift          \(drift) bytes  \(drift == 0 ? "(exact)" : "(MISMATCH)")")
        print("  elapsed        \(String(format: "%.1fs", elapsed))")
        print("  history        \(store.load().count) measurements in \(store.directory.path)")
    }

    /// Prints what changed since a chosen baseline.
    static func growth(baseline: String?) throws {
        let kind: GrowthBaseline = switch baseline ?? "previous" {
        case "previous": .previousMeasurement
        case "7d":       .sevenDays
        case "cleanup":  .lastCleanup
        default:         throw CLIError.usage("growth takes previous, 7d or cleanup")
        }

        let store = StorageSnapshotStore()
        let history = store.loadWithDiagnostics()
        print("history: \(history.snapshots.count) measurements"
              + (history.unreadableCount > 0 ? ", \(history.unreadableCount) unreadable" : ""))

        switch StorageGrowth.comparison(kind, in: history.snapshots) {
        case .insufficientHistory:
            print("  no baseline for \"\(kind.displayName)\". Take another snapshot.")
        case .notComparable(let reason):
            print("  not comparable: \(reason)")
        case .report(let report):
            print("  baseline       \(stamp(report.baseline))")
            print("  latest         \(stamp(report.latest))")
            print("")
            print("  used space     \(ByteFormatting.signedString(report.usedDeltaBytes))")
            print("")
            for growthClass in GrowthClass.allCases {
                let delta = report.classDeltas[growthClass] ?? 0
                guard delta != 0 else { continue }
                let name = growthClass.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("  \(name) \(ByteFormatting.signedString(delta))")
            }
            print("")
            if report.attributions.isEmpty {
                print("  no folder changed by enough to name.")
            }
            for attribution in report.attributions {
                let delta = ByteFormatting.signedString(attribution.deltaBytes)
                    .padding(toLength: 11, withPad: " ", startingAt: 0)
                let name = attribution.segment.displayName
                    .padding(toLength: 24, withPad: " ", startingAt: 0)
                print("  \(delta) \(name) \(FileEntry.abbreviate(attribution.path))"
                      + "  [\(describe(attribution.kind))]")
            }
        }
    }

    private static func stamp(_ snapshot: StorageSnapshot) -> String {
        snapshot.measuredAt.formatted(date: .abbreviated, time: .standard)
            + "  (\(snapshot.trigger.rawValue))"
    }

    private static func describe(_ kind: GrowthAttribution.Kind) -> String {
        switch kind {
        case .grew:                "grew"
        case .shrank:              "shrank"
        case .appeared:            "new"
        case .disappeared:         "gone"
        case .movedIn(let from):   "moved from \(FileEntry.abbreviate(from))"
        case .movedOut(let to):    "moved to \(FileEntry.abbreviate(to))"
        }
    }

    static func snapshots() async throws {
        let service = SnapshotService()
        let all = try await service.listAll()
        let deletable = try await service.deletableSnapshots()

        print("snapshots: \(all.count) total, \(deletable.count) removable")
        for snapshot in all {
            let tag = snapshot.isBootSnapshot ? "BOOT (never removable)" : "removable"
            print("  [\(tag)] \(snapshot.name)")
            print("           uuid \(snapshot.uuid)  volume \(snapshot.volumeDisk)")
        }
    }

    /// What a path occupies beside what removing it would actually give back.
    ///
    /// The two figures part company on APFS whenever blocks are shared: a folder
    /// copied within one volume is a clone of the original, and both copies then
    /// report their full size while the disk holds one. Kept in the harness so the
    /// claim can be checked against a real path without opening the app.
    static func reclaim(path: String) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let started = Date()
        let measurement = try await PrivateSizeMeasurer().measure([url])
        let elapsed = Date().timeIntervalSince(started)

        print(url.path)
        guard let measurement else {
            print("  this filesystem does not report block sharing")
            return
        }
        print("  occupies    \(ByteFormatting.string(measurement.allocatedBytes))")
        print("  frees       \(ByteFormatting.string(measurement.privateBytes))"
              + (measurement.containsSharedGroups ? "  (at least — holds whole clone families)" : ""))
        print("  shared      \(ByteFormatting.string(measurement.sharedBytes))")
        print("  files       \(measurement.fileCount)")
        print("  unreported  \(measurement.unreportedCount)")
        print("  elapsed     \(String(format: "%.2fs", elapsed))")
    }

    static func measure(path: String) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let started = Date()
        let result = try await AllocatedSizeMeasurer().measure(url)
        let elapsed = Date().timeIntervalSince(started)

        print(url.path)
        print("  size        \(ByteFormatting.string(result.allocatedBytes))")
        print("  files       \(result.fileCount)")
        print("  unreadable  \(result.unreadableCount)")
        print("  elapsed     \(String(format: "%.2fs", elapsed))")
    }
}

enum CLIError: Error { case usage(String) }
