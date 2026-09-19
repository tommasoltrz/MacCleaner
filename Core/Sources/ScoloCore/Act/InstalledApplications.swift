import Foundation

/// An application the uninstaller would agree to review.
public struct InstalledApplication: Sendable, Identifiable, Equatable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?

    public var id: String { url.path }
}

extension AppUninstallPlanner {
    /// Lists the applications in the planner's own roots, by the planner's own rules.
    ///
    /// The list and `plan(applicationURL:context:)` must agree: a card the user can
    /// click and then be told "that application is protected" is a dead control. So
    /// every guard that needs no disk walk is applied here — bundle, symbolic link,
    /// protected identifier, exclusion. The two that do need one (a protected pattern
    /// inside the bundle, Homebrew ownership) stay with the plan, which pays for the
    /// measurement anyway and reports them in the review.
    ///
    /// Top level only, like `ApplicationsScanner`: an `.app` inside a vendor folder is
    /// still reachable by dropping it on the page.
    public func installedApplications(
        context: ScanContext = ScanContext()
    ) -> [InstalledApplication] {
        let fm = FileManager.default
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        for root in applicationRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.lowercased().hasSuffix(".app") {
                let url = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
                guard seen.insert(url.path).inserted,
                      !Self.isSymbolicLink(url),
                      url.resolvingSymlinksInPath().standardizedFileURL == url,
                      let bundle = Bundle(url: url)
                else { continue }

                let identifier = Self.verifiedBundleIdentifier(bundle.bundleIdentifier)
                if let identifier {
                    guard !Self.isProtectedBundleIdentifier(identifier),
                          !protectedBundleIdentifiers.contains(identifier)
                    else { continue }
                }
                guard !context.isExcluded(url) else { continue }

                var displayName = url.deletingPathExtension().lastPathComponent
                if displayName.isEmpty { displayName = url.lastPathComponent }
                applications.append(InstalledApplication(
                    url: url, name: displayName, bundleIdentifier: identifier
                ))
            }
        }

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
