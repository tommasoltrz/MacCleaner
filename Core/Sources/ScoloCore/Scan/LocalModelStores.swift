import Foundation

/// One locally stored machine-learning model, as its runtime's store describes it.
public struct LocalModel: Sendable, Equatable {
    /// The name the user pulled it by: `llama3:8b`, `org/repo`.
    public let name: String
    public let runtime: String
    /// What stands for the model in its store — Ollama's manifest, a hub repository
    /// folder. Removing it is what makes the runtime stop listing the model.
    public let primary: URL
    /// Files only this model refers to. They go with it.
    public let exclusive: [URL]
    /// Bytes in files this model shares with another. They stay, and the row says so.
    public let sharedBytes: Int64
}

/// Reads the model stores of Ollama, the Hugging Face hub and LM Studio.
///
/// The models are usually the largest files in a developer's home and none of the
/// scanners could say so truthfully, because **a model is not a folder**. Every
/// store here is content-addressed, and what a model "is" and what removing it
/// frees are different questions:
///
/// * On this Mac on 20 Sep 2026 the one Hugging Face model, 261 MB of weights, sat
///   in a repository folder that measured **0 bytes** — it holds symbolic links.
///   The weights were in `hub/blobs/a5/<hash>`, a store shared by every repository,
///   beside a `.refs` file naming which of them use it. A row for the folder would
///   have read "0 B", and removing it would have freed nothing.
/// * Ollama keeps each layer once under `blobs/` and names it from every manifest
///   that uses it. Two tags of one model share the multi-gigabyte weights; removing
///   one frees a few kilobytes of template.
///
/// So each reader answers the second question: the files that *only* this model
/// refers to. What is shared is measured and reported, never offered. It is the
/// argument `PrivateSizeMeasurer` makes about APFS clones, one level up.
///
/// **What is verified.** The hub layout was read off a real store. Ollama and LM
/// Studio were not installed here; their readers follow each tool's published
/// layout and are tested against fixtures only. Reading manifests is Purge's idea
/// (`AIModelScanner`, github.com/jithin-sabu/purge-app); the hub's shared-blob
/// reader is this project's.
public enum LocalModelStores {

    public static func all(home: URL) -> [LocalModel] {
        ollama(home: home) + huggingFace(home: home) + lmStudio(home: home)
    }

    /// Home-relative folders these readers speak for. Whoever lists dot-folders or
    /// `~/.cache` whole must leave them alone, or the same bytes are offered twice —
    /// and `~/.ollama` whole would offer the user's `id_ed25519` with the models.
    public static let homeDotFolders: Set<String> = [".ollama", ".lmstudio"]
    public static let dotCacheFolders: Set<String> = ["huggingface", "lm-studio"]

    // MARK: - Ollama

    /// `~/.ollama/models/manifests/<host>/<namespace>/<model>/<tag>` is a JSON
    /// manifest naming a config blob and layer blobs by digest; the bytes are in
    /// `~/.ollama/models/blobs/sha256-<hex>`. `OLLAMA_MODELS` can move the store, and
    /// an app launched from the Dock does not see the shell's environment, so only
    /// the default is read.
    static func ollama(home: URL) -> [LocalModel] {
        let root = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let manifests = root.appendingPathComponent("manifests", isDirectory: true)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)

        struct Manifest: Decodable {
            struct Layer: Decodable { let digest: String }
            let config: Layer?
            let layers: [Layer]
        }

        // Every manifest first: whether a blob is exclusive is not knowable one
        // model at a time.
        var parsed: [(url: URL, digests: [String])] = []
        var references: [String: Int] = [:]
        for url in regularFiles(under: manifests) {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            else { continue }
            let digests = Array(Set(manifest.layers.map(\.digest) + [manifest.config?.digest]
                .compactMap { $0 })).sorted()
            parsed.append((url, digests))
            for digest in digests { references[digest, default: 0] += 1 }
        }

        return parsed.map { manifest in
            var exclusive: [URL] = []
            var shared: Int64 = 0
            for digest in manifest.digests {
                // `sha256-<hex>` on disk today; older stores kept the colon.
                let candidates = [digest.replacingOccurrences(of: ":", with: "-"), digest]
                guard let blob = candidates.map({ blobs.appendingPathComponent($0) })
                    .first(where: { isRegularFile($0) })
                else { continue }
                if references[digest] == 1 { exclusive.append(blob) } else { shared += allocatedSize(blob) }
            }
            return LocalModel(
                name: ollamaName(manifest.url, under: manifests),
                runtime: "Ollama", primary: manifest.url,
                exclusive: exclusive, sharedBytes: shared
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// `registry.ollama.ai/library/gemma3/4b` reads back as `gemma3:4b`, the name
    /// the user typed to pull it.
    static func ollamaName(_ manifest: URL, under root: URL) -> String {
        let parts = Array(manifest.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count))
        guard parts.count >= 4 else { return parts.joined(separator: "/") }
        let tag = parts[parts.count - 1], model = parts[parts.count - 2]
        var prefix = Array(parts.dropLast(2))
        if prefix.first == "registry.ollama.ai" { prefix.removeFirst() }
        if prefix == ["library"] { prefix = [] }
        return (prefix + ["\(model):\(tag)"]).joined(separator: "/")
    }

    // MARK: - Hugging Face hub

    /// `~/.cache/huggingface/hub/models--<org>--<repo>` (and `datasets--`,
    /// `spaces--`). Two layouts exist and both are read:
    ///
    /// * **classic** — the repository's `blobs/` holds the files, `snapshots/` links
    ///   to them. The folder is the model.
    /// * **shared blobs** — the repository's `blobs/<hash>` is a link into
    ///   `hub/blobs/<aa>/<hash>`, and `<hash>.refs` beside the target lists, one per
    ///   line, the repository paths that use it. A target is exclusive when every
    ///   line belongs to this repository. Its `.refs` and `.lock` go with it, so no
    ///   record is left pointing at a file that is gone.
    ///
    /// The hub carries `CACHEDIR.TAG`: the tool itself declares all of this a cache.
    /// The worst a wrong reading can cost is a download.
    static func huggingFace(home: URL) -> [LocalModel] {
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let sharedStore = hub.appendingPathComponent("blobs", isDirectory: true)
            .standardizedFileURL.path
        let fm = FileManager.default

        return directoryNames(hub).compactMap { folder -> LocalModel? in
            let kinds = ["models--": "", "datasets--": "dataset ", "spaces--": "space "]
            guard let kind = kinds.first(where: { folder.hasPrefix($0.key) }) else { return nil }
            let repository = hub.appendingPathComponent(folder, isDirectory: true)
            let name = kind.value + folder.dropFirst(kind.key.count)
                .replacingOccurrences(of: "--", with: "/")

            var exclusive: [URL] = []
            var shared: Int64 = 0
            let repositoryBlobs = repository.appendingPathComponent("blobs", isDirectory: true)
            for blobName in directoryNames(repositoryBlobs) {
                let link = repositoryBlobs.appendingPathComponent(blobName)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path)
                else { continue }   // classic layout: a real file, measured with the folder
                let target = URL(fileURLWithPath: destination, relativeTo: repositoryBlobs)
                    .standardizedFileURL
                guard target.path.hasPrefix(sharedStore + "/"), isRegularFile(target) else { continue }

                let refs = URL(fileURLWithPath: target.path + ".refs")
                let users = ((try? String(contentsOf: refs, encoding: .utf8)) ?? "")
                    .split(whereSeparator: \.isNewline).map(String.init)
                // No record of who uses it is not evidence that nobody else does.
                guard !users.isEmpty, users.allSatisfy({ $0.hasPrefix(folder + "/") }) else {
                    shared += allocatedSize(target)
                    continue
                }
                exclusive.append(target)
                exclusive.append(refs)
                let lock = URL(fileURLWithPath: target.path + ".lock")
                if fm.fileExists(atPath: lock.path) { exclusive.append(lock) }
            }
            return LocalModel(
                name: name, runtime: "Hugging Face", primary: repository,
                exclusive: exclusive, sharedBytes: shared
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - LM Studio

    /// `<store>/<publisher>/<repository>/` holds a model's files as plain files,
    /// with nothing shared between two of them. The store is `~/.lmstudio/models`,
    /// and `~/.cache/lm-studio/models` on installs from before it moved.
    static func lmStudio(home: URL) -> [LocalModel] {
        [".lmstudio/models", ".cache/lm-studio/models"].flatMap { relative -> [LocalModel] in
            let store = home.appendingPathComponent(relative, isDirectory: true)
            return directoryNames(store).flatMap { publisher -> [LocalModel] in
                let publisherURL = store.appendingPathComponent(publisher, isDirectory: true)
                return directoryNames(publisherURL).compactMap { repository in
                    let url = publisherURL.appendingPathComponent(repository, isDirectory: true)
                    guard isDirectory(url) else { return nil }
                    return LocalModel(
                        name: "\(publisher)/\(repository)", runtime: "LM Studio",
                        primary: url, exclusive: [], sharedBytes: 0
                    )
                }
            }
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Support

    private static func directoryNames(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func regularFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter(isRegularFile)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
