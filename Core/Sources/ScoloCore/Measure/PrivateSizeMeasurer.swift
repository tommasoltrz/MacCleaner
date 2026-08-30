import Foundation

/// What removing a set of files would actually give back.
///
/// Deliberately separate from ``SizeMeasurement``, which reports *allocated* size —
/// what the files occupy. On APFS the two figures differ whenever blocks are shared
/// between distinct files, and a Finder copy within one volume is a clone, so
/// sharing is ordinary rather than exotic. Measured on this Mac: a 1.05 GB folder
/// copied from `~/Downloads` into `~/Documents` left *both* paths reporting
/// 1056.89 MB allocated and **0 bytes private**. Deleting either one frees nothing;
/// only deleting both frees the gigabyte.
public struct PrivateSizeMeasurement: Sendable, Equatable {

    /// Bytes that no file outside this set shares, summed over everything measured.
    ///
    /// A **lower bound** on what removing the whole set frees, exact whenever the
    /// set holds at most one member of each clone family. Select both copies of a
    /// cloned folder and every file reports zero private bytes while removing them
    /// together frees the lot — ``containsSharedGroups`` says when that is in play
    /// so callers can word the figure as a minimum instead of a total.
    public var privateBytes: Int64

    /// The allocated total the same walk saw, so a caller compares two figures
    /// gathered under one set of rules rather than against a scan result that may
    /// have aged.
    public var allocatedBytes: Int64

    /// Files that answered.
    public var fileCount: Int

    /// Files that did not: unreadable, or on a filesystem that does not track block
    /// sharing. Their bytes are missing from ``privateBytes`` entirely — a non-zero
    /// count here means the figure understates by an unknown amount.
    public var unreportedCount: Int

    /// True when two or more measured files belong to the same clone family. Their
    /// shared blocks are counted private to none of them, so the sum understates
    /// what removing them together would free.
    public var containsSharedGroups: Bool

    /// Bytes this set holds that some other file also holds. The gap between what
    /// the files claim and what removing them returns.
    public var sharedBytes: Int64 { max(0, allocatedBytes - privateBytes) }

    public static let zero = PrivateSizeMeasurement()

    public init(
        privateBytes: Int64 = 0,
        allocatedBytes: Int64 = 0,
        fileCount: Int = 0,
        unreportedCount: Int = 0,
        containsSharedGroups: Bool = false
    ) {
        self.privateBytes = privateBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreportedCount = unreportedCount
        self.containsSharedGroups = containsSharedGroups
    }
}

/// Asks the filesystem how much of a set of files belongs to those files alone.
///
/// ### Why this is not folded into `AllocatedSizeMeasurer`
///
/// The kernel has to consult each file's extent map to answer, and that is not
/// free. Measured over `~/Library` (178,759 files) with `getattrlistbulk`:
/// **7.35 s for allocated size alone, 11.91 s with private size added — 62 % more**.
/// A separate `getattrlist` per file costs 96 %. Paying that on every whole-disk
/// breakdown would push a 17 s measurement past 28 s to correct a figure the
/// Dashboard already discloses as an upper bound.
///
/// So it is measured where the app makes a *promise* instead: the clean-up plan,
/// which is a bounded set. The user's 6,969-file folder measured in 97 ms warm,
/// 474 ms cold.
///
/// ### What it reads
///
/// `ATTR_CMNEXT_PRIVATESIZE` — bytes reachable only through this file — and
/// `ATTR_CMNEXT_CLONEID`, the identifier of the clone family it belongs to, both
/// from one `getattrlist` call. Note that `VOL_CAP_FMT_CLONE_MAPPING` reports *no*
/// on this Mac's data volume and the attributes answer correctly anyway, so the
/// capability bit is not a usable gate: every read is attempted and a refusal is
/// counted, never assumed.
///
/// Symlinks are skipped and hard links counted once, the same two rules
/// ``AllocatedSizeMeasurer`` follows — removing a link frees the link, and one
/// inode reached by two names is one inode.
public struct PrivateSizeMeasurer: Sendable {

    /// How often to check for cancellation, in entries. Matches
    /// ``AllocatedSizeMeasurer``.
    private let cancellationCheckInterval = 512

    public init() {}

    private static let keys: [URLResourceKey] = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    /// Measures every regular file at or under `urls`.
    ///
    /// - Returns: `nil` when files were examined and not one of them answered — the
    ///   volume does not report block sharing, and the caller must say it does not
    ///   know rather than quote a total of zero. An empty input measures to zero,
    ///   which is a real answer.
    public func measure(_ urls: [URL]) async throws -> PrivateSizeMeasurement? {
        let interval = cancellationCheckInterval
        let cancelled = CancellationFlag()

        return try await withTaskCancellationHandler {
            // Metadata syscalls, and a great many of them: keep the walk off Swift's
            // cooperative executor for the same reason the allocated-size walk is.
            try await Task.detached(priority: .userInitiated) {
                var result = PrivateSizeMeasurement()
                var claimedInodes = Set<NSObject>()
                var cloneFamilies = Set<UInt64>()
                var examined = 0

                func consider(_ url: URL, _ values: URLResourceValues?) {
                    // No metadata at all is a refusal, and it has to be counted:
                    // a path that vanished between the plan and this walk must not
                    // read as "zero bytes, nothing to free".
                    guard let values else {
                        result.unreportedCount += 1
                        return
                    }
                    // A directory, device node or socket is not a refusal — there
                    // are simply no blocks of its own to account for.
                    guard values.isRegularFile == true else { return }
                    if (values.linkCount ?? 1) > 1 {
                        guard let id = values.fileResourceIdentifier as? NSObject,
                              claimedInodes.insert(id).inserted
                        else { return }
                    }
                    guard let attributes = Self.cloneAttributes(of: url.path) else {
                        result.unreportedCount += 1
                        return
                    }
                    result.privateBytes += attributes.privateBytes
                    result.allocatedBytes += Self.allocatedSize(of: values)
                    result.fileCount += 1
                    if !cloneFamilies.insert(attributes.cloneID).inserted {
                        result.containsSharedGroups = true
                    }
                }

                for url in urls {
                    if cancelled.isCancelled { throw CancellationError() }
                    let values = try? url.resourceValues(forKeys: Set(Self.keys))

                    // A symlink is not followed, so nothing under its target is
                    // measured; the link itself frees only its own entry.
                    if values?.isSymbolicLink == true { continue }

                    guard values?.isDirectory == true else {
                        consider(url, values)
                        continue
                    }

                    // Packages are descended, as everywhere else in the app: an
                    // `.app` is a directory that happens to be presented as a file.
                    let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: Self.keys,
                        options: [],
                        errorHandler: { _, _ in
                            result.unreportedCount += 1
                            return true
                        }
                    )
                    while let child = enumerator?.nextObject() as? URL {
                        examined += 1
                        if examined % interval == 0, cancelled.isCancelled {
                            throw CancellationError()
                        }
                        consider(child, try? child.resourceValues(forKeys: Set(Self.keys)))
                    }
                }

                if result.fileCount == 0 && result.unreportedCount > 0 { return nil }
                return result
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    // MARK: - The attribute read

    struct CloneAttributes {
        var privateBytes: Int64
        /// Files in one clone family share this. A file with no clones still has
        /// one of its own, and a diverged clone is given a new one — so equality
        /// means "sharing blocks right now", which is the only question asked here.
        var cloneID: UInt64
    }

    /// One `getattrlist` for both attributes. They arrive in the fork-attribute
    /// buffer in bitmask order — private size, then clone id — behind a leading
    /// `u_int32_t` length that a short answer would leave undersized.
    static func cloneAttributes(of path: String) -> CloneAttributes? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID)

        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(
                path, &list, raw.baseAddress, raw.count,
                UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
            )
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> CloneAttributes? in
            let header = MemoryLayout<UInt32>.size
            let expected = header + MemoryLayout<off_t>.size + MemoryLayout<UInt64>.size
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= UInt32(expected)
            else { return nil }
            return CloneAttributes(
                privateBytes: Int64(raw.loadUnaligned(fromByteOffset: header, as: off_t.self)),
                cloneID: raw.loadUnaligned(
                    fromByteOffset: header + MemoryLayout<off_t>.size, as: UInt64.self
                )
            )
        }
    }

    private static func allocatedSize(of values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return 0
    }
}
