import Foundation
import Testing
@testable import ScoloCore

/// An editor's old extension versions are offered on the editor's own word.
///
/// The formats below were read out of VS Code's bundled code on 20 Sep 2026
/// (`cliProcessMain.js`): `.obsolete` is a JSON object keyed
/// `publisher.name-version[-platform]`, and a folder ending `.vsctmp` is a removal
/// the editor did not finish. It deletes both the next time it starts.
@Suite("Obsolete editor extensions")
struct EditorExtensionStoresTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-ext-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 2 * 1024 * 1024, text: String? = nil) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (text.map { Data($0.utf8) } ?? Data(count: bytes)).write(to: url)
            return url
        }

        func extensionFolder(_ name: String, in editor: String = ".vscode", bytes: Int = 2 * 1024 * 1024) throws {
            try file("\(editor)/extensions/\(name)/extension.js", bytes: bytes)
        }
    }

    /// Comparing version numbers in folder names gets this exactly backwards. The
    /// user pinned 1.0.0 with "Install Another Version…", so the editor marked the
    /// *newer* folder for removal; keeping "the highest version" would delete the
    /// one in use.
    @Test("the editor's .obsolete decides, not the version number")
    func obsoleteFileDecides() throws {
        let sandbox = try Sandbox()
        try sandbox.extensionFolder("vendor.pinned-1.0.0")
        try sandbox.extensionFolder("vendor.pinned-2.0.0")
        // Two versions and no mark: another profile may use the older one.
        try sandbox.extensionFolder("vendor.profiles-1.0.0")
        try sandbox.extensionFolder("vendor.profiles-1.1.0")
        // The key carries the manifest's casing; the folder is lowercase.
        try sandbox.extensionFolder("github.copilot-1.2.3-darwin-arm64")
        try sandbox.file(".vscode/extensions/.obsolete", text: #"""
        {"vendor.pinned-2.0.0":true,"GitHub.copilot-1.2.3-darwin-arm64":true,
         "vendor.gone-9.9.9":true,"vendor.profiles-1.0.0":false}
        """#)

        let found = EditorExtensionStores.obsolete(home: sandbox.home)

        #expect(found.map(\.url.lastPathComponent)
            == ["github.copilot-1.2.3-darwin-arm64", "vendor.pinned-2.0.0"])
        #expect(found.allSatisfy { $0.editor.name == "Visual Studio Code" })
    }

    @Test("a removal the editor did not finish is offered; an unreadable record offers nothing")
    func temporaryFoldersAndBadRecords() throws {
        let sandbox = try Sandbox()
        try sandbox.extensionFolder("vendor.half-1.0.0.vsctmp")
        try sandbox.extensionFolder("vendor.live-1.0.0")
        try sandbox.extensionFolder("vendor.old-1.0.0", in: ".cursor")
        try sandbox.extensionFolder("vendor.old-2.0.0", in: ".cursor")
        try sandbox.file(".cursor/extensions/.obsolete", text: "not json")

        let found = EditorExtensionStores.obsolete(home: sandbox.home)

        #expect(found.map(\.url.lastPathComponent) == ["vendor.half-1.0.0.vsctmp"])
    }

    @Test("an obsolete version is a safe row, held while its editor is open, and ~/.vscode is never a row")
    func inTheScan() async throws {
        let sandbox = try Sandbox()
        try sandbox.extensionFolder("vendor.tool-1.0.0", bytes: 6 * 1024 * 1024)
        try sandbox.extensionFolder("vendor.tool-2.0.0", bytes: 6 * 1024 * 1024)
        try sandbox.file(".vscode/extensions/.obsolete", text: #"{"vendor.tool-1.0.0":true}"#)

        let closed = try await PackageManagerScanner(home: sandbox.home).scan(context: ScanContext())
        let row = try #require(closed.entries.first)
        #expect(closed.entries.count == 1)
        #expect(row.url.lastPathComponent == "vendor.tool-1.0.0")
        #expect(row.displayName == "vendor.tool 1.0.0")
        #expect(row.parentDisplay.hasPrefix("Visual Studio Code marked this version for removal"))
        #expect(closed.safeToRemoveBytes == row.allocatedBytes)

        // An update waiting for a reload: the open window still runs the old version.
        let open = try await PackageManagerScanner(home: sandbox.home).scan(context: ScanContext(
            runningApplications: [FileEntry.RunningOwner(
                name: "Code", bundleIdentifier: "com.microsoft.VSCode",
                bundlePath: "/Applications/Visual Studio Code.app"
            )]
        ))
        #expect(open.entries.first?.inUseBy?.name == "Code")
        #expect(open.safeToRemoveBytes == 0)

        // Hidden Data would otherwise offer every installed extension in one row.
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())
        #expect(!hidden.entries.contains { $0.url.lastPathComponent == ".vscode" })
    }
}
