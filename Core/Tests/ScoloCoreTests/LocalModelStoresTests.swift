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

    @Test("two Ollama tags share their weights: neither frees them, and both say so")
    func ollamaSharedLayersAreNotOffered() throws {
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

        let models = LocalModelStores.ollama(home: sandbox.home)

        #expect(models.map(\.name) == ["llama3:8b", "llama3:latest", "someone/tuned:v1"])
        let latest = try #require(models.first { $0.name == "llama3:latest" })
        #expect(latest.exclusive.map(\.lastPathComponent) == ["sha256-cfgB"])
        #expect(latest.sharedBytes >= Int64(8 * mb))
        let tuned = try #require(models.first { $0.name == "someone/tuned:v1" })
        // `cfgA` is also `llama3:8b`'s, so only the weights are this model's alone.
        #expect(tuned.exclusive.map(\.lastPathComponent) == ["sha256-solo"])
        #expect(!models.flatMap(\.exclusive).contains { $0.lastPathComponent == "id_ed25519" })
    }

    // MARK: - Hugging Face

    /// The layout read off this Mac: a 261 MB model in a repository folder that
    /// measured 0 bytes.
    @Test("a hub repository of links offers the shared-store blobs only it uses")
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

        #expect(models.map(\.name) == ["org/alone", "org/other"])
        let alone = try #require(models.first { $0.name == "org/alone" })
        #expect(Set(alone.exclusive.map(\.lastPathComponent)) == ["a5only", "a5only.refs", "a5only.lock"])
        #expect(alone.sharedBytes >= Int64(7 * mb))
        let other = try #require(models.first { $0.name == "org/other" })
        #expect(other.exclusive.isEmpty, "one blob is shared, the other has lost its record")
        #expect(other.sharedBytes >= Int64(10 * mb))
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
        #expect(CleanupService.removalTargets(for: gemma, removeProtectedAppData: false)
            .map(\.url.lastPathComponent).sorted() == ["4b", "sha256-cfg", "sha256-weights"])

        let alone = try #require(hidden.entries.first { $0.displayName == "org/alone" })
        // Five megabytes of its own; the seven it shares are named and kept.
        #expect(alone.totalBytesIncludingChildren >= Int64(5 * mb))
        #expect(alone.totalBytesIncludingChildren < Int64(7 * mb))
        #expect(alone.parentDisplay.contains("shared with another model stays"))
        // `org/other` owns nothing alone: no row, since removing it would free nothing.
        #expect(!hidden.entries.contains { $0.displayName == "org/other" })

        let offered = (hidden.entries + system.entries).flatMap { [$0] + $0.children }.map(\.url.path)
        #expect(!offered.contains { $0.hasSuffix("/.ollama") || $0.hasSuffix("id_ed25519") })
        #expect(!offered.contains { $0.hasSuffix("/.cache/huggingface") })
        #expect(!offered.contains { $0.hasSuffix("b7both") })
        #expect(hidden.entries.contains { $0.url.lastPathComponent == "xet" })
        #expect(system.entries.map(\.url.lastPathComponent) == ["sometool"])
        #expect(hidden.safeToRemoveBytes == 0)
    }
}
