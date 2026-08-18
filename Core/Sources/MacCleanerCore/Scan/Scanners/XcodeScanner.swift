import Foundation

/// Xcode and iOS development leftovers: build products, downloaded device symbols,
/// simulator state and preview caches.
///
/// Ports `electron/cleaners/xcodeArtifacts.ts`, whose sizing was the reason this
/// rewrite exists. It measured every folder with
/// `execSync('du -sk "…" 2>/dev/null')` wrapped in a `catch { return 0 }`, and `du`
/// exits non-zero the moment it meets one unreadable directory. A single 0700
/// subdirectory — `DerivedData/CompilationCache.noindex` is one, on this machine —
/// was enough to report a multi-gigabyte tree as `0`, and the caller then dropped it
/// with `if (size > 0)`. The category disappeared instead of reporting a permission
/// problem. Every byte here comes from `context.measurer`, which counts the
/// unreadable entry and keeps walking, and that count is surfaced in the result.
///
/// Only scanning is ported. The original's `cleanXcodeArtifacts` shelled out to
/// `rm -rf`; removal is the remover's job in this app, not a scanner's.
public struct XcodeScanner: CategoryScanner {

    public let id: CategoryID = .xcode

    public init() {}

    // MARK: - Roots

    private struct Root {
        let url: URL
        /// `true` emits one row per immediate subdirectory rather than one row for
        /// the whole tree. Per-child rows are what make the category actionable: a
        /// single 12 GB `DerivedData` row cannot be refined, one row per project can.
        let expandsChildren: Bool
    }

    /// The original hardcoded `iOS DeviceSupport`, so symbol copies from a Watch or
    /// an Apple TV — identical directories under a different platform name — were
    /// invisible and accumulated forever.
    private static let deviceSupportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]

    private static func roots() -> [Root] {
        let developer = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Developer", directoryHint: .isDirectory)

        func root(_ relative: String, expandsChildren: Bool) -> Root {
            Root(
                url: developer.appending(path: relative, directoryHint: .isDirectory),
                expandsChildren: expandsChildren
            )
        }

        var roots: [Root] = [
            // One subdirectory per project, rebuilt by the next build.
            root("Xcode/DerivedData", expandsChildren: true),

            // `<date>/<name>.xcarchive`. Expanded per build date so a user can drop
            // last year's archives and keep this week's. See the note on
            // `isRegenerable` in `makeCacheEntry`.
            root("Xcode/Archives", expandsChildren: true),

            // SwiftUI preview build products, regenerated the next time a preview
            // renders. One blob, not per-project subdirectories.
            root("Xcode/UserData/Previews", expandsChildren: false),

            // Per-device containers: installed apps, their data, logs. Ordinary
            // user-owned directories, unlike the runtimes — see the note below.
            root("CoreSimulator/Devices", expandsChildren: true),

            // Simulator dyld shared-cache staging. The one root the original did not
            // expand, and correctly so: its children are opaque cache buckets.
            root("CoreSimulator/Caches", expandsChildren: false)
        ]

        // Symbols copied off every physical device ever attached, one directory per
        // OS build. Nothing in Xcode ever prunes them.
        for platform in deviceSupportPlatforms {
            roots.append(root("Xcode/\(platform) DeviceSupport", expandsChildren: true))
        }

        return roots
    }

    // MARK: - Deliberately not scanned
    //
    // ### `/Library/Developer/CoreSimulator` — iOS runtimes
    //
    // The machine-wide CoreSimulator directory is the largest pile in this whole
    // area: every installed iOS runtime is several gigabytes, and Xcode keeps the old
    // ones after an upgrade. It is also the one pile that cannot be reclaimed by
    // deleting files. Since Xcode 15 runtimes ship as cryptexes, mounted read-only —
    // observed on this machine:
    //
    //     /dev/disk5s1 on /Library/Developer/CoreSimulator/Cryptex/Images/bundle/
    //         SimRuntimeBundle-51D71395-… (apfs, read-only, noowners, nobrowse)
    //
    // `rm -rf` there fails with `Operation not permitted` for root exactly as it does
    // for the user: the mount is read-only, so there is no permission to grant and no
    // privilege escalation that helps. The only supported removal is
    // `xcrun simctl runtime delete <identifier>`, which unmounts the cryptex and then
    // deletes its backing image.
    //
    // `FileEntry` cannot express "worth this many bytes, but not removable by
    // unlinking" — every entry in a result is a removal candidate and the remover
    // will unlink it. A row the user can select, confirm and then watch fail is worse
    // than no row, so the runtimes stay out until an entry can carry its own removal
    // strategy. When it can, they return as `simctl runtime delete`, not as files.
    //
    // Simulator *devices* are unaffected: `~/Library/Developer/CoreSimulator/Devices`
    // is plain user-owned directories and is scanned above.
    //
    // ### `/Library/Developer/PrivateFrameworks` and `/Library/Developer/CoreDevice`
    //
    // Installed by Xcode's first-launch package, not by dragging Xcode.app into
    // /Applications — and correspondingly *not* removed when Xcode.app is dragged to
    // the Trash. They read as abandoned developer junk left in /Library long after
    // Xcode is gone, which is the trap: a stale copy from an older Xcode makes a
    // freshly installed Xcode die on launch with a dyld symbol-not-found error
    // against CoreDeviceFramework, and recovery means deleting them by hand and
    // re-running the first-launch install. They are versioned system components with
    // an installer that owns them, so this scanner never offers them.
    //
    // ### Owned by other categories
    //
    // `~/Library/Caches/com.apple.dt.Xcode` belongs to System Caches, which scans all
    // of `~/Library/Caches`. Claiming it here too would double-count it, the same
    // defect the storage breakdown had with Homebrew.

    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let fileManager = FileManager.default
        var entries: [FileEntry] = []
        var unreadableCount = 0

        for root in Self.roots() {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            // Excluding a root excludes everything beneath it, so test it before
            // paying for the walk rather than filtering the children afterwards.
            guard !context.isExcluded(root.url) else { continue }

            if root.expandsChildren {
                // One `measureChildren` call rather than a `measure` per child: it
                // shares a hard-link deduplicator across the children, so an inode
                // hard-linked into two projects' DerivedData is charged once and the
                // rows sum to the root instead of exceeding it.
                let measured = try await context.measurer.measureChildren(of: root.url)

                for (childURL, measurement) in measured {
                    // Counted for every child measured, including ones filtered out
                    // below: the number describes how much of the tree could be read,
                    // not how much is on offer.
                    unreadableCount += measurement.unreadableCount

                    // Directories only, as the original's `listSubdirs` did. A stray
                    // `.DS_Store` is a 6 KB row of pure noise in a removal list.
                    guard isDirectory(childURL) else { continue }

                    if let entry = makeCacheEntry(
                        url: childURL, measurement: measurement, context: context
                    ) {
                        entries.append(entry)
                    }
                }
            } else {
                let measurement = try await context.measurer.measure(root.url)
                unreadableCount += measurement.unreadableCount

                if let entry = makeCacheEntry(
                    url: root.url, measurement: measurement, context: context
                ) {
                    entries.append(entry)
                }
            }
        }

        // System-level simulator runtimes, which this scanner used to omit
        // entirely (see the note above). `FileEntry.manualRemoval` now exists, so
        // they are listed with a locked checkbox and their own `simctl` command
        // instead of being invisible.
        if let runtime = try await simulatorRuntimeEntry(context: context) {
            entries.append(runtime)
        }

        guard !entries.isEmpty else {
            // Ordinary outcome, not an edge case: a machine with Xcode installed but
            // nothing built, or one where every candidate is younger than
            // `protectRecentDays`, measures 0 B and the row renders disabled with no
            // disclosure triangle. Not `.unavailable` — that reason string is
            // user-facing repair copy, and a cleaner has no business telling someone
            // to install Xcode.
            var empty = ScanCategoryResult.empty(id)
            // An empty category that could not read anything is not the same as one
            // that is genuinely empty, and the Dashboard's `Unmeasured` bucket needs
            // the difference even when there is nothing to list.
            empty.unreadableCount = unreadableCount
            return empty
        }

        // `measureChildren` returns a dictionary, so iteration order varies between
        // runs; the path tiebreak keeps equal-sized rows in a stable order.
        entries.sort {
            $0.allocatedBytes == $1.allocatedBytes
                ? $0.url.path < $1.url.path
                : $0.allocatedBytes > $1.allocatedBytes
        }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: entries.reduce(0) { $0 + $1.allocatedBytes },
            entries: entries,
            availability: .available,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Entries

    /// Builds the row for an already-measured path, or `nil` when it is excluded or
    /// measured empty.
    ///
    /// Deliberately not the protocol's `makeEntry(url:kind:context:isRegenerable:)`:
    /// that helper runs its own `measure`, which would walk each tree a second time,
    /// and it discards `SizeMeasurement.unreadableCount` — the one number this
    /// scanner exists to stop losing.
    private func makeCacheEntry(
        url: URL,
        measurement: SizeMeasurement,
        context: ScanContext
    ) -> FileEntry? {
        guard measurement.allocatedBytes > 0 else { return nil }

        let lastOpened = lastOpenedDate(for: url)
        // Folder and pattern exclusions apply; the recency shield does not. Build
        // products are rewritten on every build, so "touched recently" describes
        // every DerivedData worth showing. The same leak hid Chrome's caches from
        // the System Caches category.
        guard !context.isExcluded(url) else { return nil }

        return FileEntry(
            url: url,
            kind: .cache,
            allocatedBytes: measurement.allocatedBytes,
            lastOpened: lastOpened,
            // The category is badged safe and every row is `.cache · regenerable`.
            // True of DerivedData, device symbols, previews and simulator state.
            // Archives are the exception worth flagging to whoever owns the design:
            // an `.xcarchive` holds the only dSYMs for a build that has shipped, and
            // once it is gone, crash reports from that build can no longer be
            // symbolicated. Nothing regenerates it. It is listed here because the
            // spec calls for it and because stale archives really are the biggest
            // win in this category, but "regenerable" overstates the case.
            isRegenerable: true,
            childCount: (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - Simulator runtimes

    /// One aggregated entry for `/Library/Developer/CoreSimulator`.
    ///
    /// `simctl` is invoked for the inventory only, never for sizes; the bytes come
    /// from the measurer, which stays on the start volume and therefore reports the
    /// real allocated footprint rather than double-counting the mounted image the
    /// way `du` does. One entry for the whole tree, not one per runtime: the staging
    /// and dyld caches beside the images belong to no single runtime, and a made-up
    /// per-runtime split would be a guess dressed as a measurement.
    private func simulatorRuntimeEntry(context: ScanContext) async throws -> FileEntry? {
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard !context.isExcluded(root) else { return nil }

        // Inventory. A missing or broken xcrun means no runtimes to describe, and a
        // wedged one must not hang the scan.
        let listing: String
        do {
            let data = try await ProcessRunner().run(
                "/usr/bin/xcrun", ["simctl", "runtime", "list"], timeout: .seconds(10)
            )
            listing = String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }

        // Lines look like: "iOS 18.1 (22B81) - <UUID> (Ready)". Parsed leniently:
        // a runtime we fail to parse is dropped from the description, never invented.
        var names: [String] = []
        var commands: [String] = []
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dash = trimmed.range(of: " - ") else { continue }
            let name = String(trimmed[..<dash.lowerBound])
            let rest = trimmed[dash.upperBound...]
            guard let uuid = rest.split(separator: " ").first,
                  uuid.count == 36 else { continue }
            names.append(name)
            commands.append("xcrun simctl runtime delete \(uuid)")
        }
        guard !commands.isEmpty else { return nil }

        let size = try await context.measurer.measure(root)
        guard size.allocatedBytes > 0 else { return nil }

        // Much of this tree is root-only, so the measured figure is a lower bound.
        // The explanation says so rather than letting the number pose as exact.
        let sizeCaveat = size.unreadableCount > 0
            ? " The size shown counts only what this app is allowed to read; "
                + "deleting the runtime frees more."
            : ""

        return FileEntry(
            url: root,
            displayName: "Simulator runtimes (\(names.joined(separator: ", ")))",
            kind: .diskImage,
            allocatedBytes: size.allocatedBytes,
            lastOpened: lastOpenedDate(for: root),
            manualRemoval: FileEntry.ManualRemoval(
                explanation: "A simulator runtime is a sealed, read-only system "
                    + "volume that macOS mounts for Xcode. This app cannot delete "
                    + "it, and neither can the Finder. Run the command below in "
                    + "Terminal. Xcode downloads a fresh runtime on demand from "
                    + "Settings \u{203A} Components." + sizeCaveat,
                command: commands.joined(separator: "\n")
            )
        )
    }

}
