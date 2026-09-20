import Foundation

/// The installer package an application came from, read from the system's receipts.
///
/// An application dragged into `/Applications` is the whole of itself. One put there
/// by a `.pkg` is often a part: Python's installer writes `IDLE.app` and `Python
/// Launcher.app` to `/Applications/Python 3.12`, and 468 MB of framework to
/// `/Library/Frameworks/Python.framework`, in one run. Uninstalling IDLE takes the
/// application and leaves the framework, and nothing said so.
///
/// `pkgutil --file-info <path>` is the obvious question and it does not answer it:
/// on this Mac (20 Sep 2026) it returned no `pkgid` for `IDLE.app`, nor for a file
/// inside it, while the receipt plainly lists both. So the receipts are read
/// directly. `/var/db/receipts/<id>.plist` is world-readable and gives
/// `InstallPrefixPath`; `pkgutil --files <id>` lists what the package wrote,
/// relative to that prefix, in about 13 ms. There were 48 receipts here, 29 of them
/// not Apple's, and only those whose prefix contains the application are asked.
///
/// "What else it installed" is the other receipts of the same installer run: the
/// same identifier up to its last component (`org.python.Python.*`), written within
/// ten minutes. A guess at kinship, labelled as one where it is shown — but the
/// locations themselves are the receipts' own record.
public struct InstallerReceipts: Sendable {

    public struct Package: Sendable, Equatable {
        public let identifier: String
        /// `Python_Applications.pkg`, when the receipt kept it.
        public let fileName: String?
        /// Where the same installer run put other things: absolute paths.
        public let otherLocations: [String]

        public var reviewTitle: String { "Installed by \(fileName ?? identifier)" }

        /// What the review says. It states what is on record and no more: that these
        /// folders were written by the same installer, not that the application
        /// needs them, and not that they are safe to remove by hand.
        public var reviewDetail: String {
            guard !otherLocations.isEmpty else {
                return "An installer package put this application in place. Its receipt lists "
                    + "nothing written anywhere else."
            }
            let places = ListFormatter.localizedString(byJoining: otherLocations)
            return "The same installer also wrote to \(places). Those stay: this uninstall "
                + "removes the application, not what was installed beside it."
        }
    }

    let receiptsDirectory: URL
    /// The files a package wrote, relative to its install prefix.
    let filesOf: @Sendable (String) async -> [String]

    public init() {
        let runner = ProcessRunner()
        self.init(
            receiptsDirectory: URL(fileURLWithPath: "/var/db/receipts", isDirectory: true),
            filesOf: { identifier in
                let output = try? await runner.run(
                    "/usr/sbin/pkgutil", ["--files", identifier], timeout: .seconds(10)
                )
                return String(decoding: output ?? Data(), as: UTF8.self)
                    .split(whereSeparator: \.isNewline).map(String.init)
            }
        )
    }

    init(receiptsDirectory: URL, filesOf: @escaping @Sendable (String) async -> [String]) {
        self.receiptsDirectory = receiptsDirectory
        self.filesOf = filesOf
    }

    private struct Receipt {
        let identifier: String
        let prefix: String      // absolute, no trailing slash; "" for the volume root
        let fileName: String?
        let installed: Date?
    }

    public func package(owning applicationURL: URL) async -> Package? {
        let path = applicationURL.standardizedFileURL.path
        let receipts = readReceipts()
        for receipt in receipts where path.hasPrefix(receipt.prefix + "/") {
            let relative = String(path.dropFirst(receipt.prefix.count + 1))
            guard await filesOf(receipt.identifier).contains(relative) else { continue }
            let locations = Set(siblings(of: receipt, in: receipts)
                .map { $0.prefix.isEmpty ? "/" : $0.prefix }
                .filter { !path.hasPrefix($0 + "/") && $0 != receipt.prefix })
            return Package(
                identifier: receipt.identifier,
                fileName: receipt.fileName,
                // A location inside another is the same place said twice: Python's
                // documentation is written into its framework.
                otherLocations: locations.filter { inner in
                    !locations.contains { inner != $0 && inner.hasPrefix($0 + "/") }
                }.sorted()
            )
        }
        return nil
    }

    private func siblings(of receipt: Receipt, in all: [Receipt]) -> [Receipt] {
        // `org.python.Python.PythonFramework-3.12` → `org.python.Python`. The version
        // comes off first: it has a dot of its own, and "up to the last dot" would
        // otherwise cut inside it and match nothing.
        let unversioned = receipt.identifier.replacingOccurrences(
            of: #"-\d[\d.]*$"#, with: "", options: .regularExpression
        )
        guard let stem = unversioned.range(of: ".", options: .backwards)
            .map({ String(unversioned[..<$0.lowerBound]) }), stem.contains(".")
        else { return [] }
        return all.filter { other in
            guard other.identifier != receipt.identifier,
                  other.identifier.hasPrefix(stem + ".")
            else { return false }
            guard let mine = receipt.installed, let theirs = other.installed else { return false }
            return abs(mine.timeIntervalSince(theirs)) <= 600
        }
    }

    private func readReceipts() -> [Receipt] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: receiptsDirectory.path)) ?? []
        return names.sorted().compactMap { name -> Receipt? in
            // Apple's own packages are the operating system's, not an application's.
            guard name.hasSuffix(".plist"), !name.hasPrefix("com.apple.") else { return nil }
            let url = receiptsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let identifier = plist["PackageIdentifier"] as? String
            else { return nil }
            var prefix = (plist["InstallPrefixPath"] as? String) ?? ""
            while prefix.hasSuffix("/") { prefix.removeLast() }
            while prefix.hasPrefix("/") { prefix.removeFirst() }
            return Receipt(
                identifier: identifier,
                prefix: prefix.isEmpty ? "" : "/" + prefix,
                fileName: plist["PackageFileName"] as? String,
                installed: plist["InstallDate"] as? Date
            )
        }
    }
}
