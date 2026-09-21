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
    @State private var isSidebarExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarExpanded { sidebarPanel }
            contentColumn
        }
        .animation(.smooth(duration: 0.22), value: isSidebarExpanded)
        // Under everything, through the title bar: the shell is the window.
        .background(Token.shell.ignoresSafeArea())
        // Over the whole content area, inside the safe area, so the toolbar above
        // keeps its glass and its controls. `.disabled` on the detail pane used to
        // do this job, and it reached the toolbar through the environment.
        .overlay {
            if let activity = model.activity {
                ActivityOverlay(activity: activity)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.activity)
        .task { await model.loadDashboard() }
        // Coming back to the app is the moment stale rows show: the user was just
        // in Finder, doing things this snapshot cannot know about.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.pruneVanishedEntries() }
        }
        .alert(
            "Allow Access to Other App Data",
            isPresented: $model.isShowingAppDataAccessAlert
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
        // successes — see `AppModel.Notice`. An alert waits to be read; the
        // caption it replaces was overwritten by whatever happened next.
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Panels

    /// The sidebar, inset from three edges, its surface running up behind the
    /// traffic lights while its rows begin below the header band.
    private var sidebarPanel: some View {
        SidebarView(
            model: model,
            headerBand: Token.Size.headerBand,
            isExpanded: $isSidebarExpanded
        )
            .frame(width: Token.Size.sidebarWidth)
            .background(Token.chrome)
            // The panel reaches the top of the window, where the hidden title bar
            // would otherwise make every empty spot a drag handle.
            .background(WindowDragDisabled())
            .clipShape(RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: 1)
            }
            .padding(.leading, Token.Size.shellGutter)
            .padding(.vertical, Token.Size.shellGutter)
            .frame(width: Token.Size.sidebarColumn)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            contentHeader
            detail
                .clipShape(
                    RoundedRectangle(cornerRadius: Token.Size.panelRadius, style: .continuous)
                )
                // No gutter above: the content begins directly under the header
                // band. The sidebar column carries its own trailing gutter, so the
                // leading one is needed only when there is no sidebar.
                .padding(.leading, isSidebarExpanded ? 0 : Token.Size.shellGutter)
                .padding(.trailing, Token.Size.shellGutter)
                .padding(.bottom, Token.Size.shellGutter)
        }
    }

    /// Clear of the traffic lights. With the sidebar expanded they sit on its
    /// panel; collapsed, they are in this band and the title would land under them.
    private var headerLeadingInset: CGFloat {
        isSidebarExpanded ? Token.Size.shellGutter + 6 : 76
    }

    /// The header band: the view's name and its actions, level with the traffic
    /// lights, on the shell rather than on any panel.
    private var contentHeader: some View {
        HStack(spacing: 10) {
            // Only while the sidebar is away: expanded, its own control sits inside
            // the panel, where the spec puts it.
            if !isSidebarExpanded {
                SidebarToggleButton(isExpanded: $isSidebarExpanded, isCollapsed: true)
            }
            Text(model.view.title)
                .font(.mcToolbarTitle)
                .foregroundStyle(Token.Text.primary)
            Spacer(minLength: 12)
            headerCentre
            scanButton.buttonStyle(.bordered)
            if hasRemovalAction {
                removeButton
                    .buttonStyle(.borderedProminent)
                    .tint(Token.color(.red))
            }
        }
        .padding(.leading, headerLeadingInset)
        .padding(.trailing, Token.Size.shellGutter + 6)
        .frame(height: Token.Size.headerBand)
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
        .frame(minWidth: Token.Size.minimumContentWidth)
        // One surface, edge to edge, with the cards standing off it.
        //
        // It was briefly a rounded pane inset by 10pt on a lighter frame, which
        // was the wrong way round: the page is the darkest of the three colours,
        // so an inset pane read as a hole cut into the window rather than as a
        // sheet laid on it. The sidebar is the only thing the window is divided
        // into, and its hairline is what says so.
        .background(Token.pageBackground)
        // No footer. It held a status line and each view's buttons. The buttons that
        // remove things are in the toolbar now, beside Scan, where the window's other
        // primary action already was; the ones that only choose rows (Select All,
        // Deselect All) are in each view's own header, next to the list they act on;
        // and the status line is gone (the owner's call, 21 Sep 2026) — a view shows
        // its own result, and a failure is an alert, not a caption.
        // A real sheet, so macOS supplies the titlebar attachment, the entrance
        // animation, and Escape/Return handling.
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .cleanUp:
                ConfirmationSheet(
                    // Every figure from the captured plan, so the sheet describes
                    // the operation that will actually run.
                    variant: .cleanUp(
                        itemCount: model.pendingCleanUp?.itemCount ?? 0,
                        totalBytes: model.pendingCleanUp?.totalBytes ?? 0,
                        protectedDataCount: model.pendingCleanUp?.protectedDataCount ?? 0,
                        // Absent until the private-size reading lands, a moment
                        // after the sheet appears.
                        saving: model.pendingCleanUp?.freed.flatMap {
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
                    keepReceipt: $model.keepReceipt,
                    runningOwnerNames: model.pendingCleanUp?.runningOwners.map(\.name) ?? [],
                    onConfirm: { Task { await model.performCleanUp() } },
                    onQuitAndConfirm: {
                        Task { await model.performCleanUp(quittingOwners: true) }
                    },
                    onCancel: { model.cancelCleanUp() }
                )
            case .deletePhotos:
                ConfirmationSheet(
                    variant: .deletePhotos(count: model.photoSelection.count),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.deleteSelectedPhotos() } },
                    onCancel: { model.activeSheet = nil }
                )
            case .deleteDuplicateFiles:
                ConfirmationSheet(
                    variant: .deleteDuplicateFiles(
                        count: model.fileDuplicateSelection.count,
                        totalBytes: model.fileDuplicateSelectionBytes
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.removeSelectedDuplicateFiles() } },
                    onCancel: { model.activeSheet = nil }
                )
            case .removeStorageItems:
                ConfirmationSheet(
                    variant: .removeStorageItems(
                        count: model.pendingStorageExplorerItems.count,
                        totalBytes: model.pendingStorageExplorerItems.reduce(0) {
                            $0 + $1.allocatedBytes
                        },
                        cloudItemCount: model.pendingStorageExplorerItems.filter {
                            $0.cloudState == .downloaded
                        }.count
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.performStorageExplorerRemoval() } },
                    onCancel: { model.cancelStorageExplorerRemoval() }
                )
            case .emptyTrash:
                ConfirmationSheet(
                    variant: .emptyTrash(
                        itemCount: model.trashSummary?.itemCount ?? 0,
                        totalBytes: model.trashSummary?.totalBytes ?? 0
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.emptyTrash() } },
                    onCancel: { model.activeSheet = nil }
                )
            case .uninstallApp:
                ConfirmationSheet(
                    variant: .uninstallApp(
                        applicationName: model.pendingAppUninstall?.plan.applicationName
                            ?? "this application",
                        itemCount: model.pendingAppUninstall?.itemCount ?? 0,
                        totalBytes: model.pendingAppUninstall?.totalBytes ?? 0,
                        protectedDataCount: model.pendingAppUninstall?.protectedDataCount ?? 0,
                        applicationOnly: model.pendingAppUninstall?.isApplicationOnly ?? false
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.performAppUninstall() } },
                    onCancel: { model.cancelAppUninstall() }
                )
            case .uninstallApps:
                ConfirmationSheet(
                    variant: .uninstallApps(
                        applicationCount: model.pendingBatchUninstall?.plans.count ?? 0,
                        itemCount: model.pendingBatchUninstall?.itemCount ?? 0,
                        totalBytes: model.pendingBatchUninstall?.totalBytes ?? 0,
                        protectedDataCount: model.pendingBatchUninstall?.protectedDataCount ?? 0
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.performBatchUninstall() } },
                    onCancel: { model.cancelBatchUninstall() }
                )
            }
        }
    }

    // MARK: - The toolbar's removal action

    /// Whether the current view has something to remove.
    ///
    /// The Dashboard and History describe; they take nothing away, so a button
    /// there could never become enabled, and a control whose best outcome is
    /// nothing is worse than no control. Everywhere else it is always present and
    /// disabled until there is something to act on — its place should not move
    /// about as a scan finishes or a row is ticked.
    private var hasRemovalAction: Bool {
        switch model.view {
        case .scanner, .duplicates, .storageExplorer, .trash: true
        // Only over the grid of applications. The review and done pages are steps
        // in a sequence and carry their own buttons.
        case .uninstaller: model.isShowingUninstallerLibrary
        case .dashboard, .history: false
        }
    }

    private var canRemove: Bool {
        guard model.activity == nil else { return false }
        switch model.view {
        case .scanner:         return model.hasSelection
        case .duplicates:      return model.duplicateKind == .files
            ? !model.fileDuplicateSelection.isEmpty && !model.isScanningDuplicateFiles
            : !model.photoSelection.isEmpty
        case .uninstaller:     return model.uninstallerTab == .installed
            ? !model.selectedApplicationIDs.isEmpty
            : !model.selectedLeftoverIdentifiers.isEmpty
        case .storageExplorer: return model.storageExplorer.canRemoveSelection
            && !model.isStorageExplorerMeasurementBlocked
        case .trash:           return (model.trashSummary?.itemCount ?? 0) > 0
        case .dashboard, .history: return false
        }
    }

    private func removeTapped() {
        switch model.view {
        case .scanner:    model.requestCleanUp()
        case .duplicates: model.activeSheet = model.duplicateKind == .files
            ? .deleteDuplicateFiles : .deletePhotos
        case .uninstaller: model.uninstallerTab == .installed
            ? model.reviewSelectedApplications()
            : model.requestLeftoverRemoval()
        case .storageExplorer: Task { await model.requestStorageExplorerRemoval() }
        case .trash:      model.activeSheet = .emptyTrash
        case .dashboard, .history: break
        }
    }

    /// The one button that removes things, for the view on screen.
    ///
    /// The same size and the same label inset as Scan — the two sit side by side,
    /// and a pair that differs by a couple of points reads as a mistake. It is
    /// filled where Scan is bordered, because it is the one destructive control in
    /// the window and that is worth a difference the eye can catch.
    private var removeButton: some View {
        Button(action: removeTapped) {
            HStack(spacing: 7) {
                if model.isCleaningUp || model.isRemovingDuplicateFiles {
                    ProgressView().controlSize(.small)
                }
                Text(model.removeLabel)
            }
            .toolbarButtonLabel()
        }
        .controlSize(.large)
        .disabled(!canRemove)
    }

    /// What the toolbar's principal slot used to carry: the Duplicates picker and
    /// the running scan's readout. One row, so a junk scan started elsewhere keeps
    /// its progress and its stop button when the user opens Duplicates.
    @ViewBuilder
    private var headerCentre: some View {
        if model.view == .duplicates {
            Picker("Duplicate type", selection: $model.duplicateKind) {
                ForEach(AppModel.DuplicateKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if model.isScanning {
            HStack(spacing: 8) {
                Text("Measuring \(model.scanProgress)%")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                    .monospacedDigit()
                ProgressView(value: Double(model.scanProgress), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 126)
                // The design notes the prototype had no cancel affordance and
                // that a real scan needs one.
                Button { model.cancelScan() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop scanning")
            }
            .fixedSize()
        }
    }

    private var scanButton: some View {
        Button {
            model.startScan()
        } label: {
            // Plain text, no glyph: the sparkles icon sat on the label's
            // baseline and dragged the whole line optically off-centre in the
            // capsule.
            Text("Scan").toolbarButtonLabel()
        }
        .controlSize(.large)
        .disabled(model.isBusyWithDisk)
        .help("Scan for reclaimable files")
    }
}
