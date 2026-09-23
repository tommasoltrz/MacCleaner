import SwiftUI
import ScoloCore

/// The main window: a shell, with panels laid on it.
///
/// Three separate layout responsibilities, deliberately not one stock control:
///
/// * the **shell**, one continuous surface under the whole window including the
///   title-bar area, which is what every gutter shows;
/// * the **sidebar panel**, a rounded surface inset 8pt from the top, leading and
///   bottom edges, whose background runs up behind the traffic lights while its
///   rows start below the header band;
/// * the **header band**, 52pt, on the shell beside the sidebar, holding the title
///   and this view's actions level with the traffic lights;
/// * and the **content viewport** below it, clipped to the same radius as the
///   sidebar, with a gutter on its trailing and bottom edges.
///
/// `NavigationSplitView` cannot do this. Its sidebar is a column of the window
/// rather than a panel inset from its edges, its divider is an edge rather than a
/// gutter, and its toolbar owns the full width of the window above both. Each of
/// those is the thing being replaced, so the split view goes with them — which also
/// means the toolbar goes, and the header band below is where a view's actions live
/// now.
///
/// Scrolling belongs to the sidebar and to the content viewport. The two headers
/// and the sidebar's footer do not move.
struct MainWindow: View {
    @Bindable var model: AppModel
    var settings: SettingsStore?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSidebarExpanded = true
    /// Whether the collapse control is wearing its circle. Separate from the
    /// sidebar's own state so the circle does not travel — see `toggleSidebar`.
    @State private var showsCollapsedChrome = false
    @State private var chromeRevealTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarExpanded { sidebarPanel }
            contentColumn
        }
        // One control for both states, over the layout rather than inside either
        // half of it, so it travels with the sidebar's edge instead of being
        // removed from one view and inserted into another.
        .overlay(alignment: .topLeading) {
            SidebarToggleButton(
                isCollapsed: !isSidebarExpanded,
                showsCollapsedChrome: showsCollapsedChrome,
                action: toggleSidebar
            )
            .position(x: toggleCentreX, y: Token.Size.headerBand / 2)
            .animation(
                reduceMotion ? nil : .smooth(duration: Self.sidebarTransition),
                value: isSidebarExpanded
            )
        }
        // The whole layout reaches the top of the window, not just the background
        // behind it. Without this SwiftUI keeps the hidden title bar's height as
        // safe area, so the sidebar panel began about 36pt down and the traffic
        // lights sat above it on the shell rather than on the panel.
        .ignoresSafeArea(.container, edges: .top)
        // Under everything, through the title bar: the shell is the window.
        .background(Token.shell.ignoresSafeArea())
        // Traffic-light geometry, and the window's drag turned off — see
        // `WindowChrome`, which explains why a nested opt-out cannot do it.
        .background(WindowChrome(headerBand: Token.Size.headerBand))
        .disabled(model.operations.activity != nil || model.photoDuplicates.isDeleting)
        .background(PhotoPreviewWindowPresenter(item: model.photoDuplicates.preview, model: model.photoDuplicates))
        .onChange(of: model.duplicateKind) { _, _ in model.photoDuplicates.preview = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.photoDuplicates.preview = nil
        }
        .task {
            if scenePhase == .active { model.startInitialCleanupScan() }
            await model.dashboard.loadDashboard()
        }
        .onChange(of: model.view) { _, view in
            model.photoDuplicates.preview = nil
            if view == .scanner, scenePhase == .active { model.startInitialCleanupScan() }
        }
        .onChange(of: model.isBusyWithDisk) { _, isBusy in
            if !isBusy, scenePhase == .active { model.startInitialCleanupScan() }
        }
        // Coming back to the app is the moment stale rows show: the user was just
        // in Finder, doing things this snapshot cannot know about.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.cleanup.pruneVanishedEntries()
                model.startInitialCleanupScan()
            }
        }
        .alert(
            "Allow Access to Other App Data",
            isPresented: Binding(get: { model.operations.isShowingAppDataAccessAlert }, set: { model.operations.isShowingAppDataAccessAlert = $0 })
        ) {
            Button("Open System Settings") {
                AppDataAccess.openSystemSettings()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(
                "Scolo could not move files from another app's container. "
                    + "Allow access to other application data. Then try again."
            )
        }
        // What the footer's status line used to carry, minus the routine
        // successes — see `OperationState.Notice`. An alert waits to be read; the
        // caption it replaces was overwritten by whatever happened next.
        .alert(
            model.operations.notice?.title ?? "",
            isPresented: Binding(
                get: { model.operations.notice != nil },
                set: { if !$0 { model.operations.notice = nil } }
            ),
            presenting: model.operations.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - The sidebar's own movement

    private static let sidebarTransition = 0.25
    /// Long enough that the circle cannot appear while the control is still
    /// travelling, plus a frame's margin.
    private static let collapsedChromeDelay = Duration.milliseconds(300)

    /// Where the control sits: inside the expanded panel near its trailing edge,
    /// and out on the shell clear of the traffic lights once the panel is gone.
    private var toggleCentreX: CGFloat {
        if isSidebarExpanded {
            Token.Size.sidebarColumn
                - Token.Size.expandedToggleTrailingInset
                - Token.Size.sidebarToggle / 2
        } else {
            collapsedLeadingInset + Token.Size.sidebarToggle / 2
        }
    }

    /// What the header leaves clear when there is no sidebar: the traffic lights,
    /// and the gap the reference keeps after them.
    private var collapsedLeadingInset: CGFloat {
        Token.Size.trafficLightsTrailingEdge + Token.Size.trafficLightsClearance
    }

    private func toggleSidebar() {
        let willExpand = !isSidebarExpanded
        if willExpand {
            // Take the circle off before the control starts moving. Left to the
            // change below it would be removed *inside* that animation, so it
            // would draw one frame at the far end of the journey and fade from
            // there rather than travelling.
            chromeRevealTask?.cancel()
            chromeRevealTask = nil
            showsCollapsedChrome = false
        }
        if reduceMotion {
            isSidebarExpanded = willExpand
            showsCollapsedChrome = !willExpand
        } else {
            withAnimation(.smooth(duration: Self.sidebarTransition)) {
                isSidebarExpanded = willExpand
            }
            guard !willExpand else { return }
            chromeRevealTask = Task { @MainActor in
                guard (try? await Task.sleep(for: Self.collapsedChromeDelay)) != nil else {
                    return
                }
                guard !isSidebarExpanded else { return }
                withAnimation(.easeOut(duration: 0.08)) { showsCollapsedChrome = true }
            }
        }
    }

    // MARK: - Panels

    /// The sidebar, inset from three edges, its surface running up behind the
    /// traffic lights while its rows begin below the header band.
    private var sidebarPanel: some View {
        SidebarView(model: model, headerBand: Token.Size.headerBand)
            .frame(width: Token.Size.sidebarWidth)
            .background(Token.chrome)
            .clipShape(RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: 1)
            }
            // A gutter on every side, which comes to the column's own width:
            // 8 + 218 + 8. It used to pad the leading edge only and then force
            // the result into a 234pt frame, which *centres* a 226pt view — so
            // the gap left of the panel was 12 and the gap right of it 4.
            .padding(Token.Size.shellGutter)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            contentHeader
            detail
                .clipShape(
                    RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous)
                )
        }
        // The gutters belong to the column, so the header stands in the same ones
        // the viewport does. Applied to the viewport alone, the header ran out to
        // the window's edge and its title sat six points left of the cards it
        // described.
        //
        // The sidebar supplies the leading gutter when it is visible.
        .padding(.leading, isSidebarExpanded ? 0 : Token.Size.shellGutter)
        .padding(.trailing, Token.Size.shellGutter)
        .padding(.bottom, Token.Size.shellGutter)
    }

    /// Clear of the traffic lights. With the sidebar expanded they sit on its
    /// panel and the band starts at its own gutter; collapsed, they are in this
    /// band and the title would land under them.
    private var headerLeadingInset: CGFloat {
        guard isSidebarExpanded else {
            // Measured from the window, and the column already stands in its own
            // leading gutter, so that much is taken off.
            return collapsedLeadingInset - Token.Size.shellGutter
        }
        return Token.Size.pageGutter
    }

    /// Shows the view name and actions with an outer margin above them.
    private var contentHeader: some View {
        CenteredHeaderLayout {
            HStack(spacing: 10) {
                if !isSidebarExpanded {
                    Color.clear
                        .frame(width: Token.Size.sidebarToggle, height: Token.Size.sidebarToggle)
                        .accessibilityHidden(true)
                }
                Text(model.view.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                headerCentre
            }
            HStack(spacing: 10) {
                if model.view == .duplicates || model.operations.removalCompletion?.destination != model.view {
                    pageActions
                    if hasRemovalAction {
                        removeButton
                    }
                }
            }
            .disabled(model.operations.removalCompletion?.destination == model.view)
        }
        // The page's own gutter, so the title and the actions line up with the
        // cards under them rather than with the viewport's edge.
        .padding(.leading, headerLeadingInset)
        .padding(.trailing, Token.Size.pageGutter)
        .frame(height: Token.Size.headerBand)
        .padding(.top, Token.Size.shellGutter)
        // The window moves from here and nowhere else. Behind the controls, so a
        // press on one of them is a press on it rather than the start of a drag.
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.view {
            case .dashboard:
                DashboardView(model: model, settings: settings)
            case .scanner:
                ScannerView(model: model)
            case .storageExplorer:
                StorageExplorerView(
                    model: model.storageExplorer,
                    isMeasurementBlocked: model.isStorageExplorerMeasurementBlocked
                )
            case .uninstaller:
                AppUninstallerView(model: model)
            case .history:
                CleanupHistoryView(model: model)
            case .trash:
                TrashView(model: model)
            case .duplicates:
                DuplicatesView(model: model)
            }
        }
        .allowsHitTesting(model.view == .duplicates || model.operations.removalCompletion?.destination != model.view)
        .accessibilityHidden(model.view != .duplicates && model.operations.removalCompletion?.destination == model.view)
        .overlay {
            if model.view != .duplicates {
                RemovalOperationSurface(model: model)
            }
        }
        .frame(minWidth: Token.Size.minimumContentWidth)
        // One surface, edge to edge, with the cards standing off it.
        //
        // It was briefly a rounded pane inset by 10pt on a lighter frame, which
        // was the wrong way round: the page is the darkest of the three colours,
        // so an inset pane read as a hole cut into the window rather than as a
        // sheet laid on it. The sidebar is the only thing the window is divided
        // into, and its hairline is what says so.
        .background(Token.pageBackground)
        // The header contains the actions for the current page.
        // A real sheet, so macOS supplies the titlebar attachment, the entrance
        // animation, and Escape/Return handling.
        .sheet(item: Binding(get: { model.operations.activeSheet }, set: { model.operations.activeSheet = $0 })) { sheet in
            switch sheet {
            case .cleanUp:
                ConfirmationSheet(
                    // Every figure from the captured plan, so the sheet describes
                    // the operation that will actually run.
                    variant: .cleanUp(
                        itemCount: model.cleanupRemoval.pendingCleanUp?.itemCount ?? 0,
                        totalBytes: model.cleanupRemoval.pendingCleanUp?.totalBytes ?? 0,
                        protectedDataCount: model.cleanupRemoval.pendingCleanUp?.protectedDataCount ?? 0,
                        // Absent until the private-size reading lands, a moment
                        // after the sheet appears.
                        saving: model.cleanupRemoval.pendingCleanUp?.freed.flatMap {
                            // A reading with gaps in it is no reading: an item the
                            // filesystem would not answer for could hold anything,
                            // so the sheet says nothing rather than a partial total.
                            $0.unreportedCount == 0
                                ? ConfirmationSheet.CleanupSaving(
                                    freedBytes: $0.privateBytes,
                                    isMinimum: $0.containsSharedGroups
                                )
                                : nil
                        }
                    ),
                    runningOwnerNames: model.cleanupRemoval.pendingCleanUp?.runningOwners.map(\.name) ?? [],
                    onConfirm: { Task { await model.cleanupRemoval.performCleanUp() } },
                    onQuitAndConfirm: {
                        Task { await model.cleanupRemoval.performCleanUp(quittingOwners: true) }
                    },
                    onCancel: { model.cleanupRemoval.cancelCleanUp() }
                )
            case .emptyTrash:
                ConfirmationSheet(
                    variant: .emptyTrash(
                        itemCount: model.trash.trashSummary?.itemCount ?? 0,
                        totalBytes: model.trash.trashSummary?.totalBytes ?? 0
                    ),
                    onConfirm: { Task { await model.trash.emptyTrash() } },
                    onCancel: { model.operations.activeSheet = nil }
                )
            }
        }
    }

    // MARK: - Page selection actions

    /// Review steps provide their own actions.
    private var hasRemovalAction: Bool {
        switch model.view {
        case .scanner, .duplicates, .storageExplorer, .trash: true
        // Only over the grid of applications. The review and done pages are steps
        // in a sequence and carry their own buttons.
        case .uninstaller: model.uninstaller.isShowingUninstallerLibrary
        case .dashboard, .history: false
        }
    }

    private var canRemove: Bool {
        guard !model.isBusyWithDisk else { return false }
        switch model.view {
        case .scanner:         return !model.cleanup.cleanupSelection(in: .all).isEmpty
        case .duplicates:      return model.duplicateKind == .files
            ? !model.fileDuplicates.fileDuplicateSelection.isEmpty && !model.fileDuplicates.isScanningDuplicateFiles
            : !model.photoDuplicates.selection.isEmpty && !model.photoDuplicates.isRegrouping
        case .uninstaller:     return model.uninstaller.uninstallerTab == .installed
            ? !model.uninstaller.library.selectedApplicationIDs.isEmpty
            : !model.uninstaller.library.selectedLeftoverIdentifiers.isEmpty && !model.uninstaller.library.isLoadingApplicationLeftovers
        case .storageExplorer: return model.storageExplorer.canRemoveSelection
            && !model.storageExplorer.isMapSelectionPending
            && !model.isStorageExplorerMeasurementBlocked
        case .trash:           return (model.trash.trashSummary?.itemCount ?? 0) > 0
        case .dashboard, .history: return false
        }
    }

    private func removeTapped() {
        switch model.view {
        case .scanner: model.cleanupRemoval.requestCleanUp(in: .all)
        case .duplicates:
            if model.duplicateKind == .files {
                Task { await model.fileDuplicates.removeSelectedDuplicateFiles() }
            } else {
                Task { await model.deleteSelectedPhotos() }
            }
        case .uninstaller:
            if model.uninstaller.uninstallerTab == .installed {
                model.uninstaller.moveSelectedApplicationsToTrash()
            } else {
                Task { await model.requestLeftoverRemoval() }
            }
        case .storageExplorer: Task { await model.storageRemoval.requestStorageExplorerRemoval() }
        case .trash:      model.operations.activeSheet = .emptyTrash
        case .dashboard, .history: break
        }
    }

    /// Names the next action for the current selection.
    private var removeButton: some View {
        Button(action: removeTapped) {
            HStack(spacing: 7) {
                if model.operations.isCleaningUp || model.operations.isRemovingDuplicateFiles {
                    ProgressView().controlSize(.small)
                }
                Text(model.removeLabel)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .toolbarButtonLabel()
        }
        .controlSize(.large)
        .buttonStyle(HeaderRemovalButtonStyle(
            tint: Token.color(.red)
        ))
        .disabled(!canRemove)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.removeLabel)
        .help(model.view == .scanner
              ? "Moves selected items from all filters to the Trash."
              : model.view == .uninstaller && model.uninstaller.uninstallerTab == .installed
                ? "Moves selected apps and their related files to the Trash."
                : model.removeLabel)
    }

    /// Names the operation that blocks scans on the current page.
    @ViewBuilder
    private var headerCentre: some View {
        if model.cleanup.isScanning, model.view != .scanner {
            backgroundWorkStatus(
                title: "Cleanup scan",
                detail: "\(model.cleanup.scanProgress)% complete",
                progress: Double(model.cleanup.scanProgress) / 100,
                onStop: { model.cleanup.cancelScan() }
            )
        } else if model.storageExplorer.isLoading, model.view != .storageExplorer {
            backgroundWorkStatus(
                title: "Storage Explorer scan",
                detail: "\(model.storageExplorer.progress.fileCount.formatted()) files · "
                    + ByteFormatting.string(model.storageExplorer.progress.allocatedBytes),
                onStop: { model.storageExplorer.cancel() }
            )
        } else if model.fileDuplicates.isScanningDuplicateFiles,
                  model.view != .duplicates || model.duplicateKind != .files {
            let progress = model.fileDuplicates.fileDuplicateProgress
            backgroundWorkStatus(
                title: "Duplicate file scan",
                detail: progress.map { "\($0.completed.formatted()) of \($0.total.formatted()) files" }
                    ?? "Preparing scan",
                progress: progress.flatMap { $0.total > 0 ? Double($0.completed) / Double($0.total) : nil },
                onStop: { model.fileDuplicates.cancelFileDuplicateScan() }
            )
        } else if model.photoDuplicates.isScanning,
                  model.view != .duplicates || model.duplicateKind != .photos {
            backgroundWorkStatus(
                title: "Duplicate photo scan",
                detail: "\(model.photoDuplicates.progress?.percent ?? 0)% complete",
                progress: Double(model.photoDuplicates.progress?.percent ?? 0) / 100,
                onStop: { model.photoDuplicates.cancelScan() }
            )
        } else if model.uninstaller.isPlanningAppUninstall, model.view != .uninstaller {
            backgroundWorkStatus(
                title: "Checking selected apps",
                detail: model.uninstaller.appUninstallPlanningDetail ?? "Finding related files",
                onStop: { model.uninstaller.resetAppUninstall() }
            )
        }
    }

    private func backgroundWorkStatus(
        title: String, detail: String, progress: Double? = nil,
        onStop: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Token.Text.primary)
                .frame(width: 60)
                .accessibilityLabel(title)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop \(title)")
            .help("Stop \(title)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(Token.Fill.control, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Token.Fill.controlBorder, lineWidth: Token.hairline)
        }
        .help("\(title): \(detail). Finish or stop this operation to start another scan.")
        .accessibilityElement(children: .contain)
    }

    /// Each page provides actions for its own content.
    @ViewBuilder
    private var pageActions: some View {
        switch model.view {
        case .scanner:
            Button {
                if model.cleanup.isScanning { model.cleanup.cancelScan() } else { model.startScan() }
            } label: {
                Label(
                    model.cleanup.isScanning ? "Stop Scan" : "Scan",
                    systemImage: model.cleanup.isScanning ? "stop.fill" : "magnifyingglass"
                )
            }
            .buttonStyle(PageActionButtonStyle())
            .controlSize(.large)
            .disabled(!model.cleanup.isScanning && model.isBusyWithDisk)
        case .dashboard:
            Button { Task { await model.dashboard.measureStorage() } } label: {
                Label("Refresh Overview", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.dashboard.isLoadingBreakdown)
        case .trash:
            Button { Task { await model.trash.loadTrash() } } label: {
                Label("Refresh Trash", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
        case .uninstaller:
            if model.uninstaller.isShowingUninstallerLibrary {
                Button {
                    if model.uninstaller.uninstallerTab == .installed {
                        model.uninstaller.library.loadInstalledApplications()
                    } else {
                        model.uninstaller.library.loadApplicationLeftovers()
                    }
                } label: {
                    Label(model.uninstaller.uninstallerTab == .installed ? "Refresh Apps" : "Refresh Leftovers", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.uninstaller.library.isLoadingApplicationLeftovers)
            }
        case .duplicates:
            if model.duplicateKind == .photos,
               model.photoDuplicates.results != nil, model.photoDuplicates.unavailableReason == nil {
                Button { model.startPhotoSweep() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
                .help("Scan the photo library again.")
            } else if model.duplicateKind == .files, model.fileDuplicates.fileDuplicateResults != nil {
                Button { model.startFileDuplicateScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
                .help("Scan the selected folders again.")
            }
        case .storageExplorer, .history:
            EmptyView()
        }
    }

}

/// Centers the status and keeps it clear of the title and actions.
private struct CenteredHeaderLayout: Layout {
    private let gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(2 * gap) { $0 + $1.width },
            height: sizes.map(\.height).max() ?? 38
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - leading.width - trailing.width - 2 * gap)
        let centre = subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
        let minimumX = bounds.minX + leading.width + gap + centre.width / 2
        let maximumX = bounds.maxX - trailing.width - gap - centre.width / 2
        // On narrow windows, the status moves only far enough to keep the actions clear.
        let centreX = max(minimumX, min(bounds.midX, maximumX))

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(
            at: CGPoint(x: centreX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: centre.width, height: bounds.height)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}
