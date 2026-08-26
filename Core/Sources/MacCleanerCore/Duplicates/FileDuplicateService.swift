import CryptoKit
import Darwin
import Foundation

/// Finds exact duplicate files without reading every file in full.
public actor FileDuplicateService {
    public struct Options: Sendable, Equatable {
        public var minimumLogicalBytes: Int64
        public var sampleBytes: Int
        public var readChunkBytes: Int

        public init(
            minimumLogicalBytes: Int64 = 1_000_000,
            sampleBytes: Int = 64 * 1024,
            readChunkBytes: Int = 1024 * 1024
        ) {
            precondition(minimumLogicalBytes >= 0)
            precondition(sampleBytes > 0)
            precondition(readChunkBytes > 0)
            self.minimumLogicalBytes = minimumLogicalBytes
            self.sampleBytes = sampleBytes
            self.readChunkBytes = readChunkBytes
        }
    }

    public struct Progress: Sendable, Equatable {
        public enum Stage: String, Sendable {
            case enumerating
            case sampling
            case verifying
            case done
        }

        public let stage: Stage
        public let completed: Int
        public let total: Int

        public init(stage: Stage, completed: Int = 0, total: Int = 0) {
            self.stage = stage
            self.completed = completed
            self.total = total
        }
    }

    private var running: Task<FileDuplicateResults, Error>?

    public init() {}

    public func cancel() {
        running?.cancel()
    }

    /// Scans selected roots, or joins the scan that is already running.
    public func scan(
        roots: [URL],
        options: Options = Options(),
        excludedPaths: [String] = [],
        excludedPatterns: [String] = [],
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> FileDuplicateResults {
        if let running { return try await running.value }

        let task = Task.detached(priority: .userInitiated) {
            try FileDuplicateFinder(
                options: options,
                excludedPaths: excludedPaths,
                excludedPatterns: excludedPatterns
            ).scan(roots: roots, onProgress: onProgress)
        }
        running = task
        defer { running = nil }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Synchronous file work that always runs on the detached task above.
private struct FileDuplicateFinder {
    private struct Candidate {
        let file: DuplicateFile
    }

    let options: FileDuplicateService.Options
    let excludedPaths: [String]
    let excludedPatterns: [String]

    init(
        options: FileDuplicateService.Options,
        excludedPaths: [String],
        excludedPatterns: [String]
    ) {
        self.options = options
        self.excludedPaths = excludedPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        self.excludedPatterns = excludedPatterns
    }

    func scan(
        roots requestedRoots: [URL],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) throws -> FileDuplicateResults {
        let startedAt = Date()
        let roots = normalizedRoots(requestedRoots)
        onProgress?(.init(stage: .enumerating))

        var skippedCount = 0
        var examinedCount = 0
        var seenIdentities = Set<String>()
        var bySize: [Int64: [Candidate]] = [:]

        for root in roots {
            try Task.checkCancellation()
            guard !isExcluded(root) else { continue }

            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
                .creationDateKey, .contentModificationDateKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    skippedCount += 1
                    return true
                }
            ) else {
                skippedCount += 1
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                if examinedCount.isMultiple(of: 256) { try Task.checkCancellation() }

                if isExcluded(url) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: keys) else {
                    skippedCount += 1
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                examinedCount += 1

                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    skippedCount += 1
                    continue
                }

                guard let fileSize = values.fileSize else {
                    skippedCount += 1
                    continue
                }
                let logicalBytes = Int64(fileSize)
                guard logicalBytes >= options.minimumLogicalBytes else { continue }
                guard let identity = FileIdentity.of(url) else {
                    skippedCount += 1
                    continue
                }
                guard seenIdentities.insert(identity).inserted else { continue }

                let allocatedBytes = Int64(
                    values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                )
                let file = DuplicateFile(
                    url: url,
                    logicalBytes: logicalBytes,
                    allocatedBytes: allocatedBytes,
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate
                )
                guard file.plannedIdentity == identity else {
                    skippedCount += 1
                    continue
                }
                bySize[logicalBytes, default: []].append(Candidate(file: file))
            }
        }

        let sizeCandidates = bySize.values
            .filter { $0.count > 1 }
            .flatMap { $0 }
        onProgress?(.init(stage: .sampling, total: sizeCandidates.count))

        var sampled = 0
        var bySample: [String: [Candidate]] = [:]
        for candidate in sizeCandidates {
            try Task.checkCancellation()
            defer {
                sampled += 1
                onProgress?(.init(
                    stage: .sampling, completed: sampled, total: sizeCandidates.count
                ))
            }
            guard stillMatches(candidate.file) else {
                skippedCount += 1
                continue
            }
            let digest: String
            do {
                digest = try sampledDigest(
                    candidate.file.url, size: candidate.file.logicalBytes
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedCount += 1
                continue
            }
            let key = "\(candidate.file.logicalBytes):\(digest)"
            bySample[key, default: []].append(candidate)
        }

        let fullCandidates = bySample.values
            .filter { $0.count > 1 }
            .flatMap { $0 }
        onProgress?(.init(stage: .verifying, total: fullCandidates.count))

        var verified = 0
        var byFullDigest: [String: [Candidate]] = [:]
        for candidate in fullCandidates {
            try Task.checkCancellation()
            defer {
                verified += 1
                onProgress?(.init(
                    stage: .verifying, completed: verified, total: fullCandidates.count
                ))
            }
            guard stillMatches(candidate.file) else {
                skippedCount += 1
                continue
            }
            let digest: String
            do {
                digest = try fullDigest(candidate.file.url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedCount += 1
                continue
            }
            let key = "\(candidate.file.logicalBytes):\(digest)"
            byFullDigest[key, default: []].append(candidate)
        }

        var groups: [FileDuplicateGroup] = []
        for (key, candidates) in byFullDigest where candidates.count > 1 {
            try Task.checkCancellation()
            let partition = try byteEqualSets(candidates)
            skippedCount += partition.skipped
            for equalSet in partition.sets where equalSet.count > 1 {
                let files = equalSet.map(\.file).sorted(by: keeperOrder)
                let stablePath = files.map(\.id).sorted().first ?? files[0].id
                groups.append(FileDuplicateGroup(
                    id: "\(key):\(stablePath)",
                    keeper: files[0],
                    removable: Array(files.dropFirst()),
                    contentDigest: String(key.split(separator: ":", maxSplits: 1).last ?? "")
                ))
            }
        }

        groups.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes {
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
            return $0.keeper.url.path.localizedStandardCompare($1.keeper.url.path)
                == .orderedAscending
        }
        onProgress?(.init(stage: .done, completed: groups.count, total: groups.count))

        return FileDuplicateResults(
            groups: groups,
            roots: roots,
            examinedCount: examinedCount,
            eligibleCount: bySize.values.reduce(0) { $0 + $1.count },
            skippedCount: skippedCount,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func normalizedRoots(_ roots: [URL]) -> [URL] {
        let unique = Dictionary(grouping: roots.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }, by: \.path).compactMap(\.value.first)
            .sorted { $0.pathComponents.count < $1.pathComponents.count }

        var result: [URL] = []
        for root in unique {
            guard !result.contains(where: {
                root.path == $0.path || root.path.hasPrefix($0.path + "/")
            }) else { continue }
            result.append(root)
        }
        return result
    }

    private func isExcluded(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        for component in url.pathComponents {
            if excludedPatterns.contains(where: { fnmatch($0, component, 0) == 0 }) {
                return true
            }
        }
        return false
    }

    private func stillMatches(_ file: DuplicateFile) -> Bool {
        guard FileIdentity.of(file.url) == file.plannedIdentity,
              let values = try? file.url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey
              ])
        else { return false }
        return Int64(values.fileSize ?? -1) == file.logicalBytes
            && values.contentModificationDate == file.modificationDate
    }

    private func sampledDigest(_ url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let width = UInt64(options.sampleBytes)
        let fileSize = UInt64(max(0, size))
        let middle = fileSize > width ? fileSize / 2 - min(width / 2, fileSize / 2) : 0
        let end = fileSize > width ? fileSize - width : 0
        let offsets = Array(Set([UInt64(0), middle, end])).sorted()

        for offset in offsets {
            try Task.checkCancellation()
            try handle.seek(toOffset: offset)
            var marker = offset.littleEndian
            withUnsafeBytes(of: &marker) { hasher.update(bufferPointer: $0) }
            if let data = try handle.read(upToCount: options.sampleBytes) {
                hasher.update(data: data)
            }
        }
        return Self.hex(hasher.finalize())
    }

    private func fullDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: options.readChunkBytes), !data.isEmpty
            else { break }
            hasher.update(data: data)
        }
        return Self.hex(hasher.finalize())
    }

    /// Partitions a digest bucket by actual bytes. The hash narrows the work; it is
    /// not treated as proof by itself.
    private func byteEqualSets(
        _ candidates: [Candidate]
    ) throws -> (sets: [[Candidate]], skipped: Int) {
        var sets: [[Candidate]] = []
        var skipped = 0
        for candidate in candidates {
            try Task.checkCancellation()
            var matched = false
            var failed = false
            for index in sets.indices {
                do {
                    if try filesAreEqual(candidate.file.url, sets[index][0].file.url) {
                        sets[index].append(candidate)
                        matched = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed = true
                    skipped += 1
                }
                if matched || failed {
                    break
                }
            }
            if !matched && !failed { sets.append([candidate]) }
        }
        return (sets, skipped)
    }

    private func filesAreEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? right.close() }

        while true {
            try Task.checkCancellation()
            let a = try left.read(upToCount: options.readChunkBytes) ?? Data()
            let b = try right.read(upToCount: options.readChunkBytes) ?? Data()
            if a != b { return false }
            if a.isEmpty { return true }
        }
    }

    private func keeperOrder(_ lhs: DuplicateFile, _ rhs: DuplicateFile) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Rechecks every selected copy and its keeper before moving anything.
public struct FileDuplicateRemovalService: Sendable {
    private let cleanup: CleanupService
    private let readChunkBytes: Int

    public init(
        cleanup: CleanupService = CleanupService(),
        readChunkBytes: Int = 1024 * 1024
    ) {
        self.cleanup = cleanup
        self.readChunkBytes = readChunkBytes
    }

    public func remove(
        selectedIDs: Set<DuplicateFile.ID>,
        from groups: [FileDuplicateGroup],
        privilegedFallback: Bool = false,
        keepReceipt: Bool = true
    ) async throws -> FileDuplicateRemovalOutcome {
        var entries: [FileEntry] = []
        var refused: [String] = []
        var accounted = Set<DuplicateFile.ID>()
        var staleFileIDs = Set<DuplicateFile.ID>()
        var staleGroupIDs = Set<FileDuplicateGroup.ID>()

        for group in groups {
            try Task.checkCancellation()
            let chosen = group.removable.filter { selectedIDs.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            accounted.formUnion(chosen.map(\.id))

            guard try matchesOrRefuses(group.keeper, digest: group.contentDigest) else {
                refused.append(contentsOf: chosen.map { $0.url.path })
                staleFileIDs.formUnion(chosen.map(\.id))
                staleGroupIDs.insert(group.id)
                continue
            }

            for file in chosen {
                if try matchesOrRefuses(file, digest: group.contentDigest) {
                    entries.append(FileEntry(
                        url: file.url,
                        kind: .file,
                        allocatedBytes: file.allocatedBytes
                    ))
                } else {
                    refused.append(file.url.path)
                    staleFileIDs.insert(file.id)
                }
            }
        }

        let unknown = selectedIDs.subtracting(accounted)
        refused.append(contentsOf: unknown.sorted())
        staleFileIDs.formUnion(unknown)

        var outcome = try await cleanup.remove(
            entries: entries,
            trashFirst: true,
            privilegedFallback: privilegedFallback,
            keepReceipt: keepReceipt
        )
        outcome.failed.append(contentsOf: refused)
        let permissionDenied = Set(outcome.permissionDenied)
        staleFileIDs.formUnion(outcome.failed.filter { !permissionDenied.contains($0) })
        return FileDuplicateRemovalOutcome(
            cleanup: outcome,
            staleFileIDs: staleFileIDs,
            staleGroupIDs: staleGroupIDs
        )
    }

    /// Treats an unreadable or changed file as a refusal, but preserves cancellation.
    private func matchesOrRefuses(_ file: DuplicateFile, digest: String) throws -> Bool {
        do {
            return try stillMatches(file, digest: digest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func stillMatches(_ file: DuplicateFile, digest: String) throws -> Bool {
        guard FileIdentity.of(file.url) == file.plannedIdentity,
              let values = try? file.url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey
              ]),
              Int64(values.fileSize ?? -1) == file.logicalBytes,
              values.contentModificationDate == file.modificationDate
        else { return false }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: readChunkBytes), !data.isEmpty
            else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == digest
    }
}
