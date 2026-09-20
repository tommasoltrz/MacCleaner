import Foundation
import Testing
@testable import ScoloCore

/// An application put in place by a `.pkg` is often a part of what that installer
/// wrote. The shape below is Python 3.12's, read off this Mac's receipts.
@Suite("Installer receipts")
struct InstallerReceiptsTests {

    private final class Sandbox {
        let receipts: URL
        init() throws {
            receipts = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-receipts-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: receipts) }

        func receipt(_ identifier: String, prefix: String, file: String?, installed: Date) throws {
            var plist: [String: Any] = [
                "PackageIdentifier": identifier, "InstallPrefixPath": prefix, "InstallDate": installed
            ]
            if let file { plist["PackageFileName"] = file }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: receipts.appendingPathComponent("\(identifier).plist"))
        }
    }

    @Test("the package that wrote an application is found, with where else that installer wrote")
    func owningPackageAndItsSiblings() async throws {
        let sandbox = try Sandbox()
        let run = Date(timeIntervalSince1970: 1_726_834_149)
        try sandbox.receipt("org.python.Python.PythonApplications-3.12", prefix: "Applications",
                            file: "Python_Applications.pkg", installed: run)
        try sandbox.receipt("org.python.Python.PythonFramework-3.12",
                            prefix: "Library/Frameworks/Python.framework",
                            file: "Python_Framework.pkg", installed: run.addingTimeInterval(20))
        try sandbox.receipt(
            "org.python.Python.PythonDocumentation-3.12",
            prefix: "Library/Frameworks/Python.framework/Versions/3.12/Resources/English.lproj/Documentation",
            file: nil, installed: run.addingTimeInterval(22)
        )
        try sandbox.receipt("org.python.Python.PythonUnixTools-3.12", prefix: "usr/local/bin",
                            file: nil, installed: run.addingTimeInterval(25))
        // The same vendor, a different run — 3.11, a year earlier — is not a sibling.
        try sandbox.receipt("org.python.Python.PythonFramework-3.11",
                            prefix: "Library/Frameworks/Python311.framework",
                            file: nil, installed: run.addingTimeInterval(-31_536_000))
        // Somebody else's package under the same prefix, which does not list the app.
        try sandbox.receipt("com.vendor.other", prefix: "Applications", file: nil, installed: run)
        // Apple's receipts are the operating system's and are never asked.
        try sandbox.receipt("com.apple.pkg.Core", prefix: "/", file: nil, installed: run)

        let asked = Asked()
        let receipts = InstallerReceipts(receiptsDirectory: sandbox.receipts) { identifier in
            await asked.note(identifier)
            return identifier == "org.python.Python.PythonApplications-3.12"
                ? ["Python 3.12", "Python 3.12/IDLE.app", "Python 3.12/IDLE.app/Contents"]
                : ["Other.app"]
        }

        let found = await receipts.package(
            owning: URL(fileURLWithPath: "/Applications/Python 3.12/IDLE.app")
        )
        let package = try #require(found)
        #expect(package.identifier == "org.python.Python.PythonApplications-3.12")
        #expect(package.fileName == "Python_Applications.pkg")
        // The documentation is written *into* the framework: one place, said once.
        #expect(package.otherLocations == ["/Library/Frameworks/Python.framework", "/usr/local/bin"])
        #expect(await !asked.identifiers.contains("com.apple.pkg.Core"))
        #expect(package.reviewTitle == "Installed by Python_Applications.pkg")
        #expect(package.reviewDetail.contains("/Library/Frameworks/Python.framework"))
        #expect(package.reviewDetail.contains("Those stay"))

        // Dragged into place: no receipt lists it.
        let dragged = await receipts.package(owning: URL(fileURLWithPath: "/Applications/Spotify.app"))
        #expect(dragged == nil)
    }

    private actor Asked {
        var identifiers: [String] = []
        func note(_ identifier: String) { identifiers.append(identifier) }
    }
}
