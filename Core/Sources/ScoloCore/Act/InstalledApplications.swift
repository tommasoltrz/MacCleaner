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
    /// One level into a vendor folder, and no further. `Python 3.12/IDLE.app` and
    /// `Wegde/InterviewMan Launcher.app` sat in folders the list never opened, so
    /// the only way to them was to know they could be dropped on the page. A folder
    /// inside a folder is not opened: nothing on this Mac is installed that deep,
    /// and the plan still takes a dropped `.app` from anywhere under a root.
    public func installedApplications(
        context: ScanContext = ScanContext()
    ) -> [InstalledApplication] {
        let fm = FileManager.default
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        func consider(_ url: URL) {
            guard seen.insert(url.path).inserted,
                  !Self.isSymbolicLink(url),
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  let bundle = Bundle(url: url),
                  !Self.isChromiumApplicationShim(bundle)
            else { return }

            let identifier = Self.verifiedBundleIdentifier(bundle.bundleIdentifier)
            // The plan's own verdict, so a card is never a dead control.
            guard uninstallScope(identifier: identifier, applicationURL: url) != .refused,
                  !context.isExcluded(url)
            else { return }

            var displayName = url.deletingPathExtension().lastPathComponent
            if displayName.isEmpty { displayName = url.lastPathComponent }
            applications.append(InstalledApplication(
                url: url, name: displayName, bundleIdentifier: identifier
            ))
        }

        func names(in directory: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
        }

        for root in applicationRoots {
            for name in names(in: root) {
                let url = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
                if name.lowercased().hasSuffix(".app") {
                    consider(url)
                    continue
                }
                // A vendor folder. It needs no guards of its own, and two written
                // here were dead: `consider` refuses an application whose resolved
                // path is not the one it was listed at, which covers a folder that
                // is a link out of the root, and `isExcluded` answers for everything
                // beneath an exclusion, which covers an excluded folder.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { continue }
                for child in names(in: url) where child.lowercased().hasSuffix(".app") {
                    consider(url.appendingPathComponent(child, isDirectory: true).standardizedFileURL)
                }
            }
        }

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
