import Foundation
import MacCleanerCore

// Headless harness for the scanning engine. Every measurement the app makes can be
// exercised here without launching the UI, which is how each engine phase is
// verified against the real disk:
//
//     swift run maccleaner-cli volume
//     swift run maccleaner-cli snapshots
//     swift run maccleaner-cli measure <path>
//     swift run maccleaner-cli apps

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
            case "scan":
                try await scan()
            case "apps":
                try await apps()
            case "measure":
                guard arguments.count > 1 else {
                    throw CLIError.usage("measure needs a path")
                }
                try await measure(path: arguments[1])
            default:
                print("maccleaner-cli — MacCleanerCore engine harness")
                print("commands: volume | snapshots | breakdown | scan | apps | measure <path>")
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
        let results = try await ScanCoordinator.standard().scan(
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
                    print("      \(ByteFormatting.string(entry.allocatedBytes).padding(toLength: 11, withPad: " ", startingAt: 0)) "
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
