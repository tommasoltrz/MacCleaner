import Foundation
import Testing
@testable import ScoloCore

/// A model is not a folder. Each store here is content-addressed, so what a model
/// occupies and what removing it frees are different figures — see
/// `LocalModelStores`.
@Suite("Locally stored models")
struct LocalModelStoresTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-models-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 1024, text: String? = nil) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (text.map { Data($0.utf8) } ?? Data(repeating: 0x41, count: bytes)).write(to: url)
            return url
        }

        func link(_ relative: String, to destination: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }

        /// An Ollama manifest naming a config blob and layer blobs by digest.
        func ollamaManifest(_ path: String, config: String, layers: [String]) throws {
            let layerJSON = layers.map { #"{"digest":"sha256:\#($0)","size":1}"# }.joined(separator: ",")
            try file(
                ".ollama/models/manifests/\(path)",
                text: #"{"schemaVersion":2,"config":{"digest":"sha256:\#(config)"},"layers":[\#(layerJSON)]}"#
            )
        }

        /// A hub repository in the shared-blob layout this Mac's store uses: the
        /// repository holds links, the bytes are in `hub/blobs/<aa>/<hash>`.
        func hubSharedBlob(_ hash: String, bytes: Int, usedBy repositories: [String]) throws {
            let shard = String(hash.prefix(2))
            try file(".cache/huggingface/hub/blobs/\(shard)/\(hash)", bytes: bytes)
            try file(".cache/huggingface/hub/blobs/\(shard)/\(hash).lock", bytes: 0)
            try file(
                ".cache/huggingface/hub/blobs/\(shard)/\(hash).refs",
                text: repositories.map { "\($0)/blobs/link-\(hash)" }.joined(separator: "\n") + "\n"
            )
            for repository in repositories {
                try link(".cache/huggingface/hub/\(repository)/blobs/link-\(hash)",
                         to: "../../blobs/\(shard)/\(hash)")
            }
        }
    }

    private let mb = 1024 * 1024

    // MARK: - Ollama

    /// Two tags of one model share the weights. As two rows, each read a few
    /// kilobytes and the gigabytes could be removed through neither.
    @Test("Ollama tags that share their weights are one row; a shared licence does not join models")
    func ollamaSetsShareWeights() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".ollama/models/blobs/sha256-weights", bytes: 8 * mb)
        try sandbox.file(".ollama/models/blobs/sha256-cfgA", bytes: 4096)
        try sandbox.file(".ollama/models/blobs/sha256-cfgB", bytes: 4096)
        try sandbox.file(".ollama/models/blobs/sha256-solo", bytes: 6 * mb)
        try sandbox.ollamaManifest("registry.ollama.ai/library/llama3/8b", config: "cfgA", layers: ["weights"])
        try sandbox.ollamaManifest("registry.ollama.ai/library/llama3/latest", config: "cfgB", layers: ["weights"])
        try sandbox.ollamaManifest("registry.ollama.ai/someone/tuned/v1", config: "cfgA", layers: ["solo"])
        // The user's key lives beside the models and is nobody's to offer.
        try sandbox.file(".ollama/id_ed25519", bytes: 400)
        // Ollama reads `manifests/*/*/*/*` and nothing else. A manifest-shaped file
        // a level up is not a model it knows, so it is not one here.
        try sandbox.ollamaManifest("registry.ollama.ai/library/stray", config: "cfgA", layers: ["solo"])

        let models = LocalModelStores.ollama(home: sandbox.home)

        #expect(models.map(\.memberNames) == [["llama3:8b", "llama3:latest"], ["someone/tuned:v1"]])
        let llama = try #require(models.first)
        #expect(llama.name == "llama3:8b + llama3:latest")
        #expect(llama.primary.lastPathComponent == "8b")
        // The other tag's manifest, the weights the two share, and the one config
        // that is this set's alone. `cfgA` is also `tuned`'s: it stays.
        #expect(Set(llama.exclusive.map(\.lastPathComponent)) == ["latest", "sha256-weights", "sha256-cfgB"])
        #expect(llama.sharedBytes > 0 && llama.sharedBytes < Int64(mb))

        // `cfgA` is four kilobytes. Sharing it does not make `tuned` part of llama3:
        // every Ollama model carries the same licence text somewhere.
        let tuned = try #require(models.last)
        #expect(tuned.exclusive.map(\.lastPathComponent) == ["sha256-solo"])
        #expect(!models.flatMap(\.exclusive).contains { $0.lastPathComponent == "id_ed25519" })
    }

    // MARK: - Hugging Face

    /// The layout read off this Mac: a 261 MB model in a repository folder that
    /// measured 0 bytes.
    @Test("hub repositories that share a large blob are one row; a blob with no record stays")
    func hubSharedBlobsFollowTheirRefs() throws {
        let sandbox = try Sandbox()
        try sandbox.hubSharedBlob("a5only", bytes: 5 * mb, usedBy: ["models--org--alone"])
        try sandbox.hubSharedBlob("b7both", bytes: 7 * mb,
                                  usedBy: ["models--org--alone", "models--org--other"])
        // A target with no record of who uses it is not thereby unused.
        try sandbox.hubSharedBlob("c9lost", bytes: 3 * mb, usedBy: ["models--org--other"])
        try FileManager.default.removeItem(
            at: sandbox.home.appendingPathComponent(".cache/huggingface/hub/blobs/c9/c9lost.refs")
        )

        let models = LocalModelStores.huggingFace(home: sandbox.home)

        let set = try #require(models.first)
        #expect(models.count == 1)
        #expect(set.memberNames == ["org/alone", "org/other"])
        #expect(set.primary.lastPathComponent == "models--org--alone")
        #expect(Set(set.exclusive.map(\.lastPathComponent)) == [
            "models--org--other",
            "a5only", "a5only.refs", "a5only.lock",
            "b7both", "b7both.refs", "b7both.lock"
        ])
        // `c9lost` has no record of who uses it, so it is nobody's to remove.
        #expect(set.sharedBytes >= Int64(3 * mb) && set.sharedBytes < Int64(4 * mb))
    }

    @Test("a classic hub repository keeps its own blobs, so the folder is the model")
    func hubClassicLayout() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/huggingface/hub/models--org--classic/blobs/deadbeef", bytes: 4 * mb)
        try sandbox.link(".cache/huggingface/hub/models--org--classic/snapshots/rev/model.bin",
                         to: "../../blobs/deadbeef")
        try sandbox.file(".cache/huggingface/hub/datasets--org--corpus/blobs/feed", bytes: mb)

        let models = LocalModelStores.huggingFace(home: sandbox.home)

        #expect(models.map(\.name) == ["dataset org/corpus", "org/classic"])
        #expect(models.allSatisfy { $0.exclusive.isEmpty && $0.sharedBytes == 0 })
    }

    @Test("LM Studio models are publisher/repository folders, in either store")
    func lmStudioFolders() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".lmstudio/models/lmstudio-community/Qwen-GGUF/q4.gguf", bytes: 5 * mb)
        try sandbox.file(".cache/lm-studio/models/TheBloke/Old-GGUF/q5.gguf", bytes: 3 * mb)

        let models = LocalModelStores.lmStudio(home: sandbox.home)

        #expect(models.map(\.name) == ["TheBloke/Old-GGUF", "lmstudio-community/Qwen-GGUF"])
    }

    // MARK: - In the scan

    @Test("each model is one review row carrying what only it uses; its store is listed nowhere else")
    func modelsAreRowsAndTheirStoresAreNotListedWhole() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".ollama/models/blobs/sha256-weights", bytes: 8 * mb)
        try sandbox.file(".ollama/models/blobs/sha256-cfg", bytes: 4096)
        try sandbox.ollamaManifest("registry.ollama.ai/library/gemma3/4b", config: "cfg", layers: ["weights"])
        try sandbox.file(".ollama/id_ed25519", bytes: 400)
        try sandbox.hubSharedBlob("a5only", bytes: 5 * mb, usedBy: ["models--org--alone"])
        try sandbox.hubSharedBlob("b7both", bytes: 7 * mb,
                                  usedBy: ["models--org--alone", "models--org--other"])
        try sandbox.file(".cache/huggingface/xet/chunks.bin", bytes: 2 * mb)
        try sandbox.file(".cache/sometool/blob", bytes: 2 * mb)

        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())
        let system = try await SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: sandbox.home.appendingPathComponent("Library/Logs"),
            dotCacheRoot: sandbox.home.appendingPathComponent(".cache")
        ).scan(context: ScanContext())

        let gemma = try #require(hidden.entries.first { $0.displayName == "gemma3:4b" })
        #expect(gemma.parentDisplay.hasPrefix("Ollama model"))
        #expect(gemma.totalBytesIncludingChildren >= Int64(8 * mb))
        #expect(!gemma.isRegenerable && !gemma.isRemovalLocked)
        // The weights without the manifest are a model Ollama lists and cannot load.
        #expect(gemma.removesAsUnit)
        #expect(CleanupService.removalTargets(for: gemma, removeProtectedAppData: false)
            .map(\.url.lastPathComponent).sorted() == ["4b", "sha256-cfg", "sha256-weights"])

        // The two repositories share seven megabytes, so they are one row and the
        // twelve go together. Apart, neither could have removed the seven.
        let set = try #require(hidden.entries.first { $0.displayName == "org/alone + org/other" })
        #expect(set.totalBytesIncludingChildren >= Int64(12 * mb))
        #expect(set.parentDisplay.hasPrefix("2 Hugging Face models that share their weights"))
        #expect(set.removesAsUnit)

        let offered = (hidden.entries + system.entries).flatMap { [$0] + $0.children }.map(\.url.path)
        #expect(!offered.contains { $0.hasSuffix("/.ollama") || $0.hasSuffix("id_ed25519") })
        #expect(!offered.contains { $0.hasSuffix("/.cache/huggingface") })
        #expect(offered.filter { $0.hasSuffix("b7both") }.count == 1, "offered once, by the set")
        #expect(hidden.entries.contains { $0.url.lastPathComponent == "xet" })
        #expect(system.entries.map(\.url.lastPathComponent) == ["sometool"])
        #expect(hidden.safeToRemoveBytes == 0)
    }
}
