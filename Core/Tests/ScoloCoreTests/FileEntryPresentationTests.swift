import Foundation
import Testing
@testable import ScoloCore

@Suite("File row descriptions")
struct FileEntryPresentationTests {
    @Test("Dependency descriptions keep project context and removal caveats")
    func dependencyContext() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/Projects/Reader/ios/Pods"),
                              kind: .cache, allocatedBytes: 100, safetyCaveat: "no lockfile")
        let presentation = FileEntryPresentation(entry: entry)
        #expect(presentation.summary == "iOS project dependencies · Reader / ios · no lockfile")
        #expect(presentation.icon == .package)
        #expect(!entry.regeneratesSafely)
    }

    @Test("Photo files use media descriptions while unknown folders stay generic")
    func mediaAndUnknownFolders() {
        let photo = FileEntry(url: URL(fileURLWithPath: "/Pictures/Holiday.HEIC"),
                              kind: .file, allocatedBytes: 100)
        #expect(FileEntryPresentation(entry: photo).icon == .photo)
        let folder = FileEntry(url: URL(fileURLWithPath: "/Documents/react-photos"),
                               kind: .folder, allocatedBytes: 100)
        #expect(FileEntryPresentation(entry: folder).icon == .folder)
    }

    @Test("Project detection uses dependencies instead of names or scripts")
    func manifestEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("package.json")
        #expect(FileEntryPresentation.project(at: directory) == nil)
        try Data(#"{"name":"react-example","scripts":{"build":"echo react"}}"#.utf8).write(to: manifest)
        #expect(FileEntryPresentation.project(at: directory) == .node)
        try Data(#"{"dependencies":{"react":"19.0.0"}}"#.utf8).write(to: manifest)
        #expect(FileEntryPresentation.project(at: directory) == .react)
        try Data(#"{"dependencies":{"react":"19.0.0","react-native":"0.79.0"}}"#.utf8).write(to: manifest)
        #expect(FileEntryPresentation.project(at: directory) == .reactNative)
        try Data("invalid json".utf8).write(to: manifest)
        #expect(FileEntryPresentation.project(at: directory) == nil)
        try Data(repeating: 32, count: 129 * 1024).write(to: manifest)
        #expect(FileEntryPresentation.project(at: directory) == nil)
    }
}
