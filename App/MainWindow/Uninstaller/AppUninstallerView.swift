import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacCleanerCore

/// A dedicated, review-first application uninstaller.
///
/// The empty state accepts an installed `.app`; Core then attributes only exact
/// bundle-owned or explicitly curated paths. The inventory is read-only: a dedicated
/// uninstall always includes every verified related file, and the final confirmation
/// warns about included user data.
struct AppUninstallerView: View {
    @Bindable var model: AppModel

    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.isPlanningAppUninstall || model.isUninstallingApp {
                busyState
            } else if let outcome = model.appUninstallOutcome {
                doneState(outcome)
            } else if let plan = model.appUninstallPlan {
                resultsState(plan)
            } else {
                emptyState
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let application = urls.first(where: {
                $0.pathExtension.lowercased() == "app"
            }) else { return false }
            model.planAppUninstall(application)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Token.color(.accent) : Token.Fill.controlBorder,
                        style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isDropTargeted ? Token.color(.accent).opacity(0.07) : Token.Fill.box)
                    )
                    .frame(width: 390, height: 210)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "trash.square")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(isDropTargeted ? Token.color(.accent) : Token.Text.secondary)
                            Text("Drop an application here")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Token.Text.primary)
                            Text("MacCleaner will find its verified related files for review.")
                                .font(.mcSubtitle)
                                .foregroundStyle(Token.Text.secondary)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: isDropTargeted)

                Button("Choose Application…", action: chooseApplication)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                if let error = model.appUninstallError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.textColor(.orange))
                        .multilineTextAlignment(.center)
                        .frame(width: 440)
                } else {
                    Text("Only apps installed in /Applications or ~/Applications are accepted.")
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.tertiary)
                }
            }
            // Match Scanner's empty-state rhythm: a bounded block near the top of
            // scrolling content, rather than centring against the whole window.
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
    }

    // MARK: Busy state

    private var busyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(model.isUninstallingApp
                ? "Moving the application to the Trash…" : "Finding related files…")
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)
            if model.isUninstallingApp {
                Text(model.appUninstallPlan?.isApplicationOnly == true
                    ? "Related files will stay on disk."
                    : "The application moves first. Related data stays if that move fails.")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private func resultsState(_ plan: AppUninstallPlan) -> some View {
        VStack(spacing: 0) {
            planHeader(plan)
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.appUninstallError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.textColor(.orange))
                    }

                    if let package = plan.managedPackage {
                        managedPackageCard(package)
                    }

                    completeUninstallCard(plan)

                    if !plan.preservedPaths.isEmpty {
                        Label {
                            Text(
                                "\(plan.preservedPaths.count) excluded, protected, or shared "
                                + (plan.preservedPaths.count == 1 ? "path will" : "paths will")
                                + " stay on disk."
                            )
                        } icon: {
                            Image(systemName: "shield.lefthalf.filled")
                        }
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.textColor(.orange))
                        .help(plan.preservedPaths.map(\.path).joined(separator: "\n"))
                    }

                    GroupedBox {
                        VStack(spacing: 0) {
                            let groups = groupedItems(plan)
                            ForEach(Array(groups.enumerated()), id: \.element.category) { index, group in
                                if index > 0 { HairlineDivider() }
                                itemSection(group.category, items: group.items)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            HairlineDivider()
            footer(plan)
        }
    }

    private func planHeader(_ plan: AppUninstallPlan) -> some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.applicationURL.path))
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(plan.applicationName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                Text(plan.bundleIdentifier ?? "Bundle identifier unavailable")
                    .font(.mcMonoSmall)
                    .foregroundStyle(plan.isApplicationOnly
                        ? Token.textColor(.orange) : Token.Text.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatting.string(plan.totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(plan.isApplicationOnly
                    ? "Application only"
                    : "\(plan.items.count - 1) related items")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }

            Button(action: model.resetAppUninstall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Token.Text.secondary)
            }
            .buttonStyle(.plain)
            .help("Choose another application")
        }
        .padding(16)
    }

    private func completeUninstallCard(_ plan: AppUninstallPlan) -> some View {
        GroupedBox {
            HStack(spacing: 12) {
                Image(systemName: plan.isApplicationOnly
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(plan.isApplicationOnly
                        ? Token.textColor(.orange) : Token.color(.green))

                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.isApplicationOnly
                        ? "Application-only uninstall" : "Complete uninstall")
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                    Text(
                        plan.isApplicationOnly
                            ? "MacCleaner cannot identify related files safely. Only the application will move to the Trash."
                            : plan.protectedItems.isEmpty
                            ? "Every verified related file below will move to the Trash."
                            : "Every verified related file below will move to the Trash, including profiles and settings."
                    )
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }

                Spacer()
            }
            .padding(12)
        }
    }

    private func managedPackageCard(
        _ package: AppUninstallPlan.ManagedPackage
    ) -> some View {
        GroupedBox {
            HStack(spacing: 11) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Token.textColor(.orange))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Managed by \(package.manager.rawValue)")
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                    Text(
                        "Remove the cask through Homebrew so its package receipt stays correct. "
                        + "MacCleaner will not trash only the app bundle."
                    )
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                }

            }
            .padding(12)
        }
    }

    private struct ItemGroup {
        let category: AppUninstallPlan.Item.Category
        let items: [AppUninstallPlan.Item]
    }

    private func groupedItems(_ plan: AppUninstallPlan) -> [ItemGroup] {
        AppUninstallPlan.Item.Category.allCases.compactMap { category in
            let items = plan.items.filter { $0.category == category }
            return items.isEmpty ? nil : ItemGroup(category: category, items: items)
        }
    }

    private func itemSection(
        _ category: AppUninstallPlan.Item.Category,
        items: [AppUninstallPlan.Item]
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(categoryTitle(category))
                    .mcEyebrowStyle()
                Spacer()
                Text(ByteFormatting.string(items.reduce(0) { $0 + $1.allocatedBytes }))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)

            HairlineDivider()

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { HairlineDivider() }
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: AppUninstallPlan.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.mcBody)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isProtectedUserData {
                        Badge(text: "user data").fixedSize()
                    } else if item.content == .regenerable {
                        Badge(text: "regenerable", style: .safe).fixedSize()
                    } else if item.content == .appComponent {
                        Badge(text: "app component").fixedSize()
                    }
                }

                Text(FileEntry.abbreviate(item.url.path))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatting.string(item.allocatedBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Token.Text.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .hoverHighlight()
    }

    private func footer(_ plan: AppUninstallPlan) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.items.count == 1
                    ? "1 item to remove" : "\(plan.items.count) items to remove")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.primary)
                Text(ByteFormatting.string(plan.totalBytes))
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }

            Spacer()

            Button("Choose Another…", action: chooseApplication)
                .buttonStyle(SecondaryButtonStyle())

            if let package = plan.managedPackage {
                Button("Copy Homebrew Uninstall Command") {
                    copyHomebrewCommand(package)
                }
                .buttonStyle(.borderedProminent)
                .help(package.uninstallCommand)
            } else {
                Button(uninstallButtonTitle(plan), action: model.requestAppUninstall)
                    .buttonStyle(.borderedProminent)
                    .tint(Token.color(.red))
                    .controlSize(.regular)
            }
        }
        .padding(16)
    }

    private func uninstallButtonTitle(_ plan: AppUninstallPlan) -> String {
        let action = plan.isApplicationOnly ? "Uninstall Application" : "Uninstall"
        return "\(action) · \(ByteFormatting.string(plan.totalBytes))"
    }

    private func copyHomebrewCommand(_ package: AppUninstallPlan.ManagedPackage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(package.uninstallCommand, forType: .string)
    }

    // MARK: Done state

    private func doneState(_ outcome: CleanupOutcome) -> some View {
        let applicationName = model.lastUninstalledApplicationName ?? "Application"
        let failed = outcome.failed
        let applicationFailed = model.appUninstallError != nil && outcome.removedCount == 0

        return VStack(spacing: 15) {
            Spacer()
            Image(systemName: applicationFailed
                ? "exclamationmark.triangle.fill"
                : (failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 54))
                .foregroundStyle(failed.isEmpty && !applicationFailed
                    ? Token.color(.green) : Token.color(.orange))
            Text(applicationFailed ? "Could not uninstall \(applicationName)" : "\(applicationName) uninstalled")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Token.Text.primary)
            Text("Moved \(ByteFormatting.string(outcome.freedBytes)) to the Trash.")
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)

            if let error = model.appUninstallError {
                Text(error)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.textColor(.orange))
                    .multilineTextAlignment(.center)
                    .frame(width: 420)
            } else if !failed.isEmpty {
                Text("\(failed.count) related \(failed.count == 1 ? "item remains" : "items remain") on disk.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.textColor(.orange))
            }

            Button("Uninstall Another Application", action: model.resetAppUninstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: Helpers

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application to Uninstall"
        panel.prompt = "Review Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.planAppUninstall(url) }
        }
    }

    private func categoryTitle(_ category: AppUninstallPlan.Item.Category) -> String {
        switch category {
        case .application: "Application"
        case .support: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers & Scripts"
        case .logs: "Logs"
        case .state: "Saved State"
        case .helpers: "Helpers & Launch Items"
        }
    }
}

/// Local one-pixel rule. The scanner's identically purposed divider is private to
/// its file so the Uninstaller keeps its own tiny spelling rather than widening
/// that implementation detail into an app-wide API.
private struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline)
    }
}
