import AppKit
import SwiftUI
import ScoloCore

/// A dedicated, review-first application uninstaller.
///
/// The page opens on the installed applications; choosing one (or dropping an
/// `.app`) starts its review. Core then attributes only exact
/// bundle-owned or explicitly curated paths. The inventory is read-only: a dedicated
/// uninstall always includes every verified related file, and the final confirmation
/// warns about included user data.
struct AppUninstallerView: View {
    @Bindable var model: AppModel

    @State private var isDropTargeted = false
    @State private var searchText = ""
    /// By name, which is the order the list arrives in, so the page opens still.
    /// It opened on `largest`: alphabetical while the bundles were measured, then
    /// every card moving at once when the last size came in — a reshuffle nobody
    /// had asked for, on a page the user had only just opened. Sorting by size is
    /// now something the user chooses, and the one move follows their choice.
    ///
    /// There is no "Unsorted" option, though one was asked for: the list has no
    /// order of its own to show — `AppUninstallPlanner.installedApplications` sorts
    /// by name — so the label would sit beside `Name` and mean the same thing.
    @State private var sortOrder: SortOrder = .name

    /// The page's two lists. Leftovers are here as well as in the Scanner because
    /// this is where the question gets asked: whoever came to uninstall an
    /// application is the person who wants to know what the last one left behind.
    private enum Tab: String, CaseIterable {
        case installed = "Installed"
        case leftovers = "Leftovers"
    }
    @State private var tab: Tab = .installed
    /// Removed applications whose files are disclosed, by bundle identifier.
    @State private var expandedLeftovers: Set<String> = []

    private enum SortOrder: String, CaseIterable {
        case name = "Name"
        case largest = "Largest"
    }

    var body: some View {
        Group {
            if model.isPlanningAppUninstall, let url = model.appUninstallPlanningURL {
                planningState(url)
            } else if model.isPlanningAppUninstall {
                busyState
            } else if let outcome = model.batchUninstallOutcome {
                batchDoneState(outcome)
            } else if let outcome = model.appUninstallOutcome {
                doneState(outcome)
            } else if let review = model.batchUninstallReview {
                batchReviewState(review)
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

    // MARK: Installed applications

    /// The page opens on what is installed. Clicking a card ticks it; the chevron in
    /// its corner opens that application's review. A tick is a choice of *which*
    /// applications, never consent to what goes with them: several ticked
    /// applications are each planned and listed in a batch review before the sheet.
    /// Dropping an `.app` still works, for one inside a vendor folder. The page has
    /// no footer: its actions sit in this header, beside the cards they act on.
    private var emptyState: some View {
        VStack(spacing: 0) {
            libraryHeader
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.appUninstallError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.textColor(.orange))
                    }

                    if tab == .leftovers {
                        leftoversList
                    } else if let applications = model.installedApplications {
                        let shown = visibleApplications(applications)
                        if shown.isEmpty {
                            ContentUnavailableView {
                                Label(
                                    applications.isEmpty ? "No Applications" : "No Results",
                                    systemImage: "xmark.app"
                                )
                            } description: {
                                Text(applications.isEmpty
                                    ? "Nothing removable was found in /Applications or ~/Applications."
                                    : "No application matches “\(searchText)”.")
                            }
                            .frame(maxWidth: .infinity, minHeight: 320)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(shown) { application in
                                    ApplicationCard(
                                        application: application,
                                        bytes: model.installedApplicationBytes[application.id],
                                        isSelected: model.selectedApplicationIDs
                                            .contains(application.id),
                                        toggle: { model.toggleApplicationSelection(application) },
                                        open: { model.planAppUninstall(application.url) }
                                    )
                                }
                            }
                            // One move, when the order changes: the measured sort
                            // arriving, a new sort order, a search narrowing.
                            .animation(.smooth(duration: 0.4), value: shown.map(\.id))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                        .strokeBorder(
                            Token.color(.accent),
                            style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                        )
                        .background(
                            Token.color(.accent).opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear { model.loadInstalledApplications() }
        // Read when the tab is first opened, and again on each return to it: the
        // disk it describes changes whenever something is uninstalled.
        .onChange(of: tab) { _, newTab in
            if newTab == .leftovers { model.loadApplicationLeftovers() }
        }
    }

    // MARK: Leftovers

    @ViewBuilder
    private var leftoversHeaderContent: some View {
        if model.selectedLeftoverIdentifiers.isEmpty {
            Text(leftoversSummary)
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
                .help("Files whose application is no longer installed. "
                    + "They are that application's settings and data: nothing puts them back.")
        } else {
            Text("\(model.selectedLeftoverIdentifiers.count) selected · "
                 + ByteFormatting.string(model.selectedLeftoverBytes))
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
            Button("Deselect All") { model.selectedLeftoverIdentifiers.removeAll() }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
        }

        Spacer()

        if !model.selectedLeftoverIdentifiers.isEmpty {
            // The ellipsis is the promise: the sheet says how many items, and that
            // they move to the Trash, before anything does.
            Button("Remove \(model.selectedLeftoverIdentifiers.count)…",
                   action: model.requestLeftoverRemoval)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Token.color(.red))
                .disabled(model.activity != nil)
                .fixedSize()
        }
    }

    private var leftoversSummary: String {
        guard let leftovers = model.applicationLeftovers else { return "Looking for leftovers…" }
        let count = leftovers.groups.count
        guard count > 0 else { return "No leftovers" }
        return "\(count) removed \(count == 1 ? "application" : "applications") · "
            + ByteFormatting.string(leftovers.totalBytes)
    }

    @ViewBuilder
    private var leftoversList: some View {
        if let leftovers = model.applicationLeftovers {
            if leftovers.groups.isEmpty {
                ContentUnavailableView {
                    Label("No Leftovers", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing was found that a removed application left behind.")
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                // Never ticked for the user: whether a removed application's
                // settings matter depends on whether it is coming back.
                GroupedBox {
                    VStack(spacing: 0) {
                        let groups = leftovers.groups.sorted { $0.totalBytes > $1.totalBytes }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { HairlineDivider() }
                            leftoverRow(group)
                            if expandedLeftovers.contains(group.bundleIdentifier) {
                                ForEach(group.items, id: \.id) { item in
                                    HairlineDivider()
                                    itemRow(item).padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // Bones, not a spinner over an empty page: the list is a few rows.
            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        if index > 0 { HairlineDivider() }
                        skeletonRow(nameWidth: 180, pathWidth: 120).frame(height: 46)
                    }
                }
            }
        }
    }

    private func leftoverRow(_ group: OrphanedAppLeftoverPlan.Group) -> some View {
        let isSelected = model.selectedLeftoverIdentifiers.contains(group.bundleIdentifier)
        let isExpanded = expandedLeftovers.contains(group.bundleIdentifier)
        let holdsUserData = group.items.contains(where: \.isProtectedUserData)
        return HStack(spacing: 10) {
            Button {
                if isExpanded { expandedLeftovers.remove(group.bundleIdentifier) }
                else { expandedLeftovers.insert(group.bundleIdentifier) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Token.Text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(group.items.count) files")

            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in model.toggleLeftoverSelection(group.bundleIdentifier) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The identifier is what is known. The application is gone, and
                    // a friendlier name would be a guess about something not here.
                    Text(group.bundleIdentifier)
                        .font(.mcBody)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if holdsUserData { Badge(text: "includes user data").fixedSize() }
                }
                Text("No installed application owner · "
                     + (group.items.count == 1 ? "1 file" : "\(group.items.count) files"))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(ByteFormatting.string(group.totalBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { model.toggleLeftoverSelection(group.bundleIdentifier) }
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if tab == .leftovers {
                leftoversHeaderContent
            } else {
                installedHeaderContent
            }
        }
        // Fixed, so the first tick does not push the grid down by the difference
        // between a line of caption text and a button.
        .frame(height: Self.headerControlHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var installedHeaderContent: some View {
        // A selection takes over the summary's place: the count the user is
        // building matters more than the total they are not acting on.
        if model.selectedApplicationIDs.isEmpty {
            Text(librarySummary)
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
                .help("Sizes are the application itself. Its related files are found when you open it.")
        } else {
            Text("\(model.selectedApplicationIDs.count) selected")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
            Button("Deselect All", action: model.clearApplicationSelection)
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
        }

        Spacer()

        Picker("Sort", selection: $sortOrder) {
            ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()

        // The one thing in this header that may narrow. At a fixed 180 pt it
        // won the space and the button beside it was cut to "Unins…" — a
        // truncated label on the destructive control is the wrong one to lose.
        FindField(text: $searchText, findRequest: model.findRequest)
            .frame(minWidth: 90, idealWidth: 180, maxWidth: 180)

        if !model.selectedApplicationIDs.isEmpty {
            // The ellipsis is the promise: related files are found and shown
            // before anything is asked.
            Button("Uninstall \(model.selectedApplicationIDs.count)…",
                   action: model.reviewSelectedApplications)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Token.color(.red))
                .disabled(model.activity != nil)
                .fixedSize()
        }
    }

    /// Tall enough for the header's tallest control, a regular bordered button.
    private static let headerControlHeight: CGFloat = 24

    /// The total appears only once every card has its figure; a sum of the bundles
    /// measured so far would read as the whole and grow under the user's eyes.
    private var librarySummary: String {
        guard let applications = model.installedApplications else { return "Reading applications…" }
        let count = applications.count == 1 ? "1 application" : "\(applications.count) applications"
        let sizes = applications.compactMap { model.installedApplicationBytes[$0.id] }
        guard sizes.count == applications.count else { return "\(count) · measuring…" }
        return "\(count) · \(ByteFormatting.string(sizes.reduce(0, +)))"
    }

    private func visibleApplications(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? applications : applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        // `Largest` waits for every size. Sorting on partial figures reshuffled
        // the grid once per application measured; chosen early, the cards fill in
        // where they stand and move once, together.
        guard sortOrder == .largest, model.installedApplicationsMeasured else { return matching }
        // An application that could not be measured compares as -1 and keeps its
        // alphabetical place at the end.
        let bytes = model.installedApplicationBytes
        return matching.enumerated().sorted { lhs, rhs in
            let l = bytes[lhs.element.id] ?? -1, r = bytes[rhs.element.id] ?? -1
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)
    }

    // MARK: Busy state

    /// Several applications being planned — there is no one header to show. The
    /// uninstall itself is a removal, and removals are shown by
    /// the window-wide `ActivityOverlay`; a second spinner here said the same thing.
    private var busyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Finding related files…")
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)
            if let detail = model.appUninstallPlanningDetail {
                Text(detail)
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Planning one application

    /// The review's own frame, at once: the header is known from the bundle the
    /// moment the chevron is pressed, and the close button cancels the planning.
    /// Only what has to be found — sizes and related files — is bone.
    private func planningState(_ url: URL) -> some View {
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = url.lastPathComponent }
        return VStack(spacing: 0) {
            reviewHeader(
                url: url, name: name,
                identifier: Bundle(url: url)?.bundleIdentifier ?? " ",
                identifierIsWarning: false
            ) {
                // The bundle's size is already on the card, so it is shown and named
                // for what it is. The review's figure is a different one — the
                // application plus everything found — and replaces it, with its own
                // caption, when the plan lands.
                VStack(alignment: .trailing, spacing: 2) {
                    if let bytes = model.installedApplicationBytes[url.path] {
                        Text(ByteFormatting.string(bytes))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else {
                        SkeletonBone(width: 64, height: 12).skeletonPulse().frame(height: 18)
                    }
                    Text("Application · finding related files…")
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }

                // The review's button, in its place and disabled, so the figures do
                // not slide left by its width when the plan lands. Nothing can be
                // uninstalled before there is a plan, which is what disabled says.
                // An application-only or Homebrew plan carries a longer label and
                // will still shift; the ordinary one does not.
                Button("Uninstall") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(Token.color(.red))
                    .disabled(true)
                    .fixedSize()
            }
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupedBox { skeletonRow(nameWidth: 130, pathWidth: 250).frame(height: 58) }
                    GroupedBox {
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { index in
                                if index > 0 { HairlineDivider() }
                                skeletonRow(
                                    nameWidth: [150, 110, 170, 95, 140, 120][index],
                                    pathWidth: [280, 240, 310, 220, 260, 300][index]
                                )
                                .frame(height: 42)
                            }
                        }
                    }
                }
                .skeletonPulse()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDisabled(true)
            .accessibilityLabel("Finding related files")
        }
    }

    private func skeletonRow(nameWidth: CGFloat, pathWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            SkeletonBone(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBone(width: nameWidth, height: 10)
                SkeletonBone(width: pathWidth, height: 8)
            }
            Spacer()
            SkeletonBone(width: 54, height: 10)
        }
        .padding(.horizontal, 13)
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

                    if let package = plan.installerPackage {
                        installerPackageCard(package)
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

        }
    }

    private func planHeader(_ plan: AppUninstallPlan) -> some View {
        reviewHeader(
            url: plan.applicationURL, name: plan.applicationName,
            identifier: plan.bundleIdentifier ?? "Bundle identifier unavailable",
            identifierIsWarning: plan.isApplicationOnly
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatting.string(plan.totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(plan.isApplicationOnly
                    ? "Application only"
                    : "\(plan.items.count - 1) related items")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }

            if let package = plan.managedPackage {
                Button("Copy Homebrew Uninstall Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(package.uninstallCommand, forType: .string)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize()
                .help(package.uninstallCommand)
            } else {
                // The size is in the figures beside it, so the label does not
                // repeat it.
                Button(plan.isApplicationOnly ? "Uninstall Application" : "Uninstall",
                       action: model.requestAppUninstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(Token.color(.red))
                    .disabled(model.activity != nil)
                    .fixedSize()
            }
        }
    }

    /// One header for the review and for its loading state, so nothing moves when
    /// the plan arrives.
    private func reviewHeader<Figures: View>(
        url: URL, name: String, identifier: String, identifierIsWarning: Bool,
        @ViewBuilder figures: () -> Figures
    ) -> some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(identifier)
                    .font(.mcMonoSmall)
                    .foregroundStyle(identifierIsWarning
                        ? Token.textColor(.orange) : Token.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // The figure and the action keep their width; the name beside them is
            // what truncates when the window is narrow.
            figures().fixedSize()

            Button(action: model.resetAppUninstall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Token.Text.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to all applications")
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
                            ? "Scolo cannot identify related files safely. Only the application will move to the Trash."
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

    /// An application a `.pkg` put in place is often a part of what that installer
    /// wrote — Python's leaves 468 MB of framework behind IDLE. Information, not a
    /// gate, so it is drawn in the ordinary tone and not the Homebrew card's orange.
    /// The words are Core's, where they are tested.
    private func installerPackageCard(
        _ package: InstallerReceipts.Package
    ) -> some View {
        GroupedBox {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 17))
                    .foregroundStyle(Token.Text.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(package.reviewTitle)
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                    Text(package.reviewDetail)
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
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
                        + "Scolo will not trash only the app bundle."
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
            Text("Moved \(ByteFormatting.string(outcome.removedBytes)) to the Trash.")
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

    // MARK: Several applications

    private func batchReviewState(_ review: AppModel.BatchUninstallReview) -> some View {
        VStack(spacing: 0) {
            batchReviewHeader(review)
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !review.plans.isEmpty {
                        GroupedBox {
                            VStack(spacing: 0) {
                                ForEach(Array(review.plans.enumerated()), id: \.element.applicationURL) { index, plan in
                                    if index > 0 { HairlineDivider() }
                                    batchPlanRow(plan)
                                }
                            }
                        }
                    }
                    if !review.setAside.isEmpty {
                        setAsideBox(review.setAside, title: "Not part of this uninstall")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

        }
    }

    private func batchReviewHeader(_ review: AppModel.BatchUninstallReview) -> some View {
        HStack(spacing: 10) {
            Text("\(review.plans.count) applications · \(review.itemCount) items")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)

            Spacer()

            Button("Back", action: model.resetAppUninstall)
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
            Button("Uninstall · \(ByteFormatting.string(review.totalBytes))",
                   action: model.requestBatchUninstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Token.color(.red))
                .disabled(review.plans.isEmpty || model.activity != nil)
                .fixedSize()
        }
        .frame(height: Self.headerControlHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func batchPlanRow(_ plan: AppUninstallPlan) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.applicationURL.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plan.applicationName)
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                    if !plan.protectedItems.isEmpty {
                        Badge(text: "includes user data").fixedSize()
                    }
                }
                Text(plan.isApplicationOnly
                    ? "Application only — related files cannot be identified safely"
                    : "Application and \(plan.items.count - 1) related "
                        + (plan.items.count == 2 ? "item" : "items"))
                    .font(.mcCaption)
                    .foregroundStyle(plan.isApplicationOnly
                        ? Token.textColor(.orange) : Token.Text.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(ByteFormatting.string(plan.totalBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .frame(height: 48)
    }

    private func setAsideBox(
        _ applications: [AppModel.SetAsideApplication], title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).mcEyebrowStyle()
            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(Array(applications.enumerated()), id: \.offset) { index, application in
                        if index > 0 { HairlineDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.name)
                                .font(.mcBody.weight(.medium))
                                .foregroundStyle(Token.Text.primary)
                            Text(application.reason)
                                .font(.mcCaption)
                                .foregroundStyle(Token.textColor(.orange))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func batchDoneState(_ outcome: AppModel.BatchUninstallOutcome) -> some View {
        let clean = outcome.setAside.isEmpty && outcome.survivorCount == 0
        let count = outcome.uninstalled.count
        return ScrollView {
            VStack(spacing: 15) {
                Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(clean ? Token.color(.green) : Token.color(.orange))
                Text(count == 0
                    ? "No applications were uninstalled"
                    : "\(count) \(count == 1 ? "application" : "applications") uninstalled")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Token.Text.primary)
                if count > 0 {
                    Text("\(ListFormatter.localizedString(byJoining: outcome.uninstalled)). "
                        + "Moved \(ByteFormatting.string(outcome.removedBytes)) to the Trash.")
                        .font(.mcBody)
                        .foregroundStyle(Token.Text.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                if outcome.survivorCount > 0 {
                    Text("\(outcome.survivorCount) related "
                        + (outcome.survivorCount == 1 ? "item remains" : "items remain")
                        + " on disk.")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.textColor(.orange))
                }
                if !outcome.setAside.isEmpty {
                    setAsideBox(outcome.setAside, title: "Still installed")
                        .frame(maxWidth: 460)
                }
                Button("Done", action: model.resetAppUninstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    // MARK: Helpers

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

/// Application icons by path. `NSWorkspace.icon(forFile:)` is synchronous and a
/// card's body runs again whenever any figure lands, so an uncached grid asked for
/// every icon once per application measured.
@MainActor
private enum ApplicationIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}

/// One installed application. The card toggles its tick; the chevron opens the
/// review. The chevron is a sibling laid over the card, not a button inside the
/// card's label — a button nested in a button's label does not get its own clicks.
private struct ApplicationCard: View {
    let application: InstalledApplication
    let bytes: Int64?
    let isSelected: Bool
    let toggle: () -> Void
    let open: () -> Void

    @State private var isChevronHovered = false

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 6) {
                Image(nsImage: ApplicationIcons.icon(for: application.url))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .padding(.bottom, 2)
                Text(application.name)
                    .font(.mcBody.weight(.medium))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ZStack {
                    if let bytes {
                        Text(ByteFormatting.string(bytes))
                            .font(.mcCaption)
                            .foregroundStyle(Token.Text.secondary)
                            .transition(.opacity)
                    } else {
                        SkeletonBone(width: 52, height: 9)
                            .skeletonPulse()
                            .transition(.opacity)
                    }
                }
                .frame(height: 14)
                .animation(.easeOut(duration: 0.25), value: bytes == nil)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, minHeight: 126)
            // Before the box fill: the highlight is a background, and a background
            // added after the fill would sit underneath it and never show.
            .hoverHighlight(radius: Token.Radius.card)
            .background(
                isSelected ? Token.color(.accent).opacity(0.10) : Token.Fill.box, in: shape
            )
            .overlay(shape.strokeBorder(
                isSelected ? Token.color(.accent) : Token.Fill.boxBorder,
                lineWidth: isSelected ? 1.5 : Token.hairline
            ))
            .overlay(alignment: .topLeading) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Token.color(.accent) : Token.Text.disabled)
                    .padding(8)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bytes.map { "\(application.name), \(ByteFormatting.string($0))" }
            ?? application.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this application for uninstall")
        .overlay(alignment: .topTrailing) {
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isChevronHovered ? Token.Text.primary : Token.Text.tertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        isChevronHovered ? Token.Fill.control : .clear,
                        in: RoundedRectangle(cornerRadius: Token.Radius.control)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isChevronHovered = $0 }
            .padding(5)
            .help("Review \(application.name) and its related files")
            .accessibilityLabel("Review \(application.name)")
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
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
