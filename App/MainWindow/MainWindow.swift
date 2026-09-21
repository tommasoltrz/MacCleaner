import SwiftUI
import ScoloCore

/// The main window: source list, unified toolbar, and a status bar per view.
///
/// Everything structural here is stock. `NavigationSplitView` supplies the sidebar
/// and its material, `.toolbar` supplies the unified Liquid Glass toolbar with live
/// scroll-under blur, and `safeAreaInset` supplies the status bar. The handoff's
/// pixel values for these are descriptions of what the native chrome already does —
/// it says so directly: "Prefer the stock control over recreating it."
struct MainWindow: View {
    @Bindable var model: AppModel
    var settings: SettingsStore?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The sidebar is always there and cannot be collapsed. It is the whole of
        // this app's navigation — seven sections, all of them visible — so hiding
        // it only ever strands the user somewhere with no way back, and the toolbar
        // control for hiding it is a control whose best outcome is nothing.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(Token.Size.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(model.view.title)
                .toolbar { toolbarContent }
        }
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
    /// The same control as Scan, in the same size, with the same label inset — the
    /// two sit side by side, and a pair that differs by a couple of points reads as
    /// a mistake rather than as a hierarchy. It is told apart by its tint and by
    /// saying what it would take, not by being a different shape.
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // One principal item holding both. The Duplicates picker used to take the
        // slot alone, so a junk scan started elsewhere lost its readout and its
        // stop button the moment the user opened Duplicates.
        if model.view == .duplicates || model.isScanning {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 14) {
                if model.view == .duplicates {
                    Picker("Duplicate type", selection: $model.duplicateKind) {
                        ForEach(AppModel.DuplicateKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                }
                if model.isScanning {
                HStack(spacing: 8) {
                    // Breathing room on both sides: a principal item otherwise butts
                    // straight against the title on its left and the Scan button on
                    // its right.
                    Color.clear.frame(width: 8, height: 1)
                    Text("Measuring \(model.scanProgress)%")
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
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

                    Color.clear.frame(width: 8, height: 1)
                }
                }
                }
            }
        }

        // Scan comes first and quietly. It used to be the window's one filled
        // capsule, which made starting a measurement look like the point of the
        // app; what the user came to do is remove something.
        ToolbarItem(placement: .primaryAction) {
            scanButton.buttonStyle(.bordered)
        }

        // Then what this view removes, on the right. The same control as Scan —
        // `.bordered`, `.large`, same label inset — tinted red, because the pair
        // sits side by side and two buttons that differ slightly in height read as
        // a mistake. Always there on a view that can remove anything, disabled
        // until it can; see `hasRemovalAction`.
        if hasRemovalAction {
            ToolbarItem(placement: .primaryAction) {
                removeButton
                    .buttonStyle(.bordered)
                    .tint(Token.color(.red))
            }
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
