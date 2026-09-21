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

    /// Whether the current view has something to remove. The Uninstaller is not
    /// here: which of its four buttons applies depends on the page and tab it is
    /// showing, which is that view's own state, so its actions stay in its header.
    private var hasRemovalAction: Bool {
        switch model.view {
        case .scanner, .duplicates, .storageExplorer, .trash: true
        case .dashboard, .uninstaller, .history: false
        }
    }

    /// The one button that removes things, for the view on screen. Inert rather
    /// than hidden when nothing is selected, so its place beside Scan is stable.
    @ViewBuilder
    private var removalButton: some View {
        switch model.view {
        case .scanner:
            Button { model.requestCleanUp() } label: {
                HStack(spacing: 7) {
                    if model.isCleaningUp { ProgressView().controlSize(.small) }
                    Text(model.isCleaningUp ? "Moving to Trash…" : model.cleanUpLabel)
                }
            }
            .disabled(!model.hasSelection || model.isCleaningUp)

        case .duplicates:
            switch model.duplicateKind {
            case .files:
                Button { model.activeSheet = .deleteDuplicateFiles } label: {
                    HStack(spacing: 7) {
                        if model.isRemovingDuplicateFiles { ProgressView().controlSize(.small) }
                        Text(model.isRemovingDuplicateFiles
                             ? "Moving to Trash…" : model.fileDuplicateSelectionLabel)
                    }
                }
                .disabled(
                    model.fileDuplicateSelection.isEmpty || model.isRemovingDuplicateFiles
                        || model.isScanningDuplicateFiles
                )
            case .photos:
                Button(model.photoSelectionLabel) { model.activeSheet = .deletePhotos }
                    .disabled(model.photoSelection.isEmpty)
            }

        case .storageExplorer:
            let explorer = model.storageExplorer
            Button(model.storageExplorerSelectionLabel) {
                Task { await model.requestStorageExplorerRemoval() }
            }
            .disabled(!explorer.canRemoveSelection || model.isStorageExplorerMeasurementBlocked)
            .help(
                explorer.canRemoveSelection
                    ? "Review the selected items before they move to the Trash."
                    : "Select only unlocked items to continue."
            )

        case .trash:
            Button("Empty Trash") { model.activeSheet = .emptyTrash }
                .disabled((model.trashSummary?.itemCount ?? 0) == 0 || model.activity != nil)

        case .dashboard, .uninstaller, .history:
            EmptyView()
        }
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

        // What this view removes, to the left of Scan. Red, since Scan is the accent
        // and two accent capsules side by side would read as one choice; sized like
        // Scan so the pair sits on one line.
        if hasRemovalAction {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .primaryAction) {
                    removalButton
                        .buttonStyle(.glassProminent)
                        .tint(Token.color(.red))
                        .controlSize(.large)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    removalButton
                        .buttonStyle(.borderedProminent)
                        .tint(Token.color(.red))
                        .controlSize(.large)
                }
            }
        }

        // Two spellings of one button. On macOS 26 it supplies its own Liquid
        // Glass capsule, and the toolbar item's shared background has to be
        // hidden or a second capsule appears behind it. Earlier systems have
        // neither: `.borderedProminent` is the accent-filled capsule those
        // releases draw for exactly this button, and there is no shared
        // background to hide. The branch is at the item, not inside the label,
        // because `sharedBackgroundVisibility` is a toolbar modifier.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) {
                scanButton.buttonStyle(.glassProminent)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                scanButton.buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanButton: some View {
        Button {
            model.startScan()
        } label: {
            // Plain text, no glyph: the sparkles icon sat on the label's
            // baseline and dragged the whole line optically off-centre in the
            // capsule. The App Store's offer button it is modelled on is
            // text-only too.
            Text("Scan for Junk")
                .fontWeight(.semibold)
                .padding(.vertical, 1)
                .padding(.horizontal, 8)
        }
        // Large, like the App Store's offer button: a filled capsule at regular
        // size read as an afterthought next to the 52pt bar.
        .controlSize(.large)
        .disabled(model.isBusyWithDisk)
        .help("Scan for reclaimable files")
    }
}
