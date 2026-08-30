import Foundation

/// Feature prints, persisted between sweeps.
///
/// Fingerprinting is by far the most expensive thing this feature does: with
/// Optimize Mac Storage most thumbnails are not on disk, so each print costs an
/// iCloud round-trip before Vision ever runs. Across a 13,000-asset library that is
/// minutes of network time, and repeating it on every sweep would make the feature
/// unusable — and would re-download the user's library each time.
///
/// Stored as packed binary rather than JSON: a 768-float vector per asset is ~3 KB
/// raw, and the same data as JSON text runs several times larger for no benefit.
public struct FingerprintCache: Sendable {

    /// Bumped whenever the on-disk layout changes.
    private static let formatVersion: UInt32 = 1
    private static let magic: [UInt8] = Array("MCFP".utf8)

    /// The Vision request revision these prints came from. Prints from different
    /// revisions are not comparable, so a mismatch discards the whole file rather
    /// than silently mixing two vector spaces.
    public let visionRevision: UInt32
    public let elementCount: UInt32
    public private(set) var prints: [String: PhotoFingerprint]

    public init(visionRevision: UInt32, elementCount: UInt32, prints: [String: PhotoFingerprint] = [:]) {
        self.visionRevision = visionRevision
        self.elementCount = elementCount
        self.prints = prints
    }

    public subscript(assetID: String) -> PhotoFingerprint? {
        get { prints[assetID] }
        set { prints[assetID] = newValue }
    }

    /// Drops prints for assets no longer in the library, so a cache cannot grow
    /// without bound as photos are deleted.
    public mutating func retaining(_ liveIDs: Set<String>) {
        prints = prints.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Storage

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Scolo", isDirectory: true)
            .appendingPathComponent("photo-fingerprints.bin")
    }

    public func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        for value in [Self.formatVersion, visionRevision, elementCount, UInt32(prints.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        // Sorted so the file is byte-stable for a given set of prints.
        for (id, fingerprint) in prints.sorted(by: { $0.key < $1.key }) {
            let idBytes = Array(id.utf8)
            withUnsafeBytes(of: UInt16(idBytes.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: idBytes)
            for element in fingerprint.vector {
                withUnsafeBytes(of: element.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Returns nil when the file is absent, truncated, or from another revision —
    /// every one of which means "fingerprint again", never "use what is there".
    public static func decode(_ data: Data, expectingRevision revision: UInt32) -> FingerprintCache? {
        var offset = 0
        func take(_ count: Int) -> Data? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        func takeUInt32() -> UInt32? {
            take(4).map { $0.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        }

        guard let header = take(4), Array(header) == magic,
              let version = takeUInt32(), version == formatVersion,
              let storedRevision = takeUInt32(), storedRevision == revision,
              let elementCount = takeUInt32(), elementCount > 0,
              let entryCount = takeUInt32()
        else { return nil }

        var prints: [String: PhotoFingerprint] = [:]
        prints.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            guard let lengthBytes = take(2) else { return nil }
            let length = Int(lengthBytes.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
            })
            guard let idData = take(length), let id = String(data: idData, encoding: .utf8),
                  let vectorData = take(Int(elementCount) * 4)
            else { return nil }

            let vector = vectorData.withUnsafeBytes { raw -> [Float] in
                (0..<Int(elementCount)).map { index in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: index * 4, as: UInt32.self
                    )))
                }
            }
            prints[id] = PhotoFingerprint(vector: vector)
        }

        return FingerprintCache(visionRevision: revision, elementCount: elementCount, prints: prints)
    }

    public static func load(expectingRevision revision: UInt32) -> FingerprintCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data, expectingRevision: revision)
    }

    public func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? encoded().write(to: url, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
