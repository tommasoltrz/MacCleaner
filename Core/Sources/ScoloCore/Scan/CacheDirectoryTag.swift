import Foundation

/// The Cache Directory Tagging Specification: a file named `CACHEDIR.TAG` whose
/// first 43 bytes are a fixed signature, written by a tool at the root of a
/// directory it declares to be its cache. Backup tools read it to skip the folder;
/// `uv`, Cargo's `target` and Hugging Face's `hub` write it.
///
/// It is the one piece of evidence about a cache that comes from the tool itself.
/// A folder under `~/.cache` is somewhere a cache *may* live. This Mac's held a
/// Codex runtime with its binaries there, and nothing about its position said so.
public enum CacheDirectoryTag {

    public static let fileName = "CACHEDIR.TAG"
    public static let signature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// True when `directory` carries a tag with the right signature. A file of that
    /// name holding anything else is not a tag — the specification says so, and a
    /// name alone is never evidence here.
    public static func isPresent(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(fileName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let expected = Data(signature.utf8)
        guard let head = try? handle.read(upToCount: expected.count) else { return false }
        return head == expected
    }
}
