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
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(Token.Size.sidebarWidth)
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
            case .safeToRemove:
                FilteredEntriesView(model: model, filter: .safeToRemove)
            case .needsReview:
                FilteredEntriesView(model: model, filter: .needsReview)
            }
        }
        .frame(minWidth: Token.Size.minimumContentWidth)
        .background(Token.pageBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView(message: model.currentStatusMessage) {
                statusBarTrailing
            }
        }
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
                        permanentCount: model.pendingCleanUp?.permanentCount ?? 0,
                        protectedDataCount: model.pendingCleanUp?.protectedDataCount ?? 0
                    ),
                    keepReceipt: $model.keepReceipt,
                    onConfirm: { Task { await model.performCleanUp() } },
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
            }
        }
    }

    /// Actions that belong to the current view.
    ///
    /// The Dashboard's `Scan for Junk` button is gone from here — it duplicated the
    /// toolbar's, which is present on every view. (`Storage Report…` is omitted
    /// entirely; it was never specified beyond a label.) The Scanner's Clean Up pair
    /// stays, because those act on the selection this view owns.
    @ViewBuilder
    private var statusBarTrailing: some View {
        switch model.view {
        case .dashboard:
            // Keep this in the same lifecycle as the card: startup preparation is
            // already a measurement even before the disk walk itself begins.
            Button(model.isDashboardLoading ? "Measuring…" : "Measure Again") {
                Task { await model.measureStorage() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isDashboardLoading)

        case .scanner, .safeToRemove, .needsReview:
            // The tile drill-downs promise a sweep — "safe to remove" especially —
            // and a sweep should not mean ticking every row by hand. It sits beside
            // Deselect All rather than up in the header, where the two halves of
            // one decision were a window apart. The Scanner is a browsing view with
            // per-category controls, so it keeps Deselect All alone.
            if model.view == .safeToRemove || model.view == .needsReview {
                Button("Select All") { model.selectAllInCurrentView() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!model.canSelectAllInCurrentView || model.isCleaningUp)
            }

            Button("Deselect All") { model.deselectAll() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.hasSelection || model.isCleaningUp)

            Button { model.requestCleanUp() } label: {
                HStack(spacing: 7) {
                    if model.isCleaningUp {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isCleaningUp ? "Moving to Trash…" : model.cleanUpLabel)
                }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                // Nothing selected means nothing to confirm; the design renders the
                // button inert rather than hiding it, so its place stays predictable.
                .disabled(!model.hasSelection || model.isCleaningUp)
        case .duplicates:
            switch model.duplicateKind {
            case .files:
                Button("Select All") { model.selectAllFileDuplicates() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(
                        model.fileDuplicateGroups.isEmpty
                            || model.isScanningDuplicateFiles
                            || model.isRemovingDuplicateFiles
                    )

                Button("Deselect All") { model.deselectAllFileDuplicates() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(
                        model.fileDuplicateSelection.isEmpty || model.isRemovingDuplicateFiles
                            || model.isScanningDuplicateFiles
                    )

                Button { model.activeSheet = .deleteDuplicateFiles } label: {
                    HStack(spacing: 7) {
                        if model.isRemovingDuplicateFiles {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            model.isRemovingDuplicateFiles
                                ? "Moving to Trash…" : model.fileDuplicateSelectionLabel
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Token.color(.red))
                .disabled(
                    model.fileDuplicateSelection.isEmpty || model.isRemovingDuplicateFiles
                        || model.isScanningDuplicateFiles
                )

            case .photos:
                Button("Select All") { model.selectAllRemovablePhotos() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.photoGroups.isEmpty)

                // This action excludes groups that need manual review.
                Button("Certain Only (\(model.certainRemovableCount))") {
                    model.selectCertainPhotosOnly()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.certainRemovableCount == 0)

                Button("Deselect All") { model.deselectAllPhotos() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.photoSelection.isEmpty)

                Button(model.photoSelectionLabel) { model.activeSheet = .deletePhotos }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(Token.color(.red))
                    .disabled(model.photoSelection.isEmpty)
            }

        case .storageExplorer:
            let explorer = model.storageExplorer
            if !explorer.selectedItems.isEmpty {
                Text("\(explorer.selectedItems.count) selected · "
                     + ByteFormatting.string(explorer.selectedBytes))
                    .foregroundStyle(Token.Text.secondary)
            }

            Button("Deselect All") { explorer.selection.removeAll() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(explorer.selection.isEmpty || model.isRemovingStorageItems)

            Button(model.storageExplorerSelectionLabel) {
                Task { await model.requestStorageExplorerRemoval() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Token.color(.red))
            .disabled(!explorer.canRemoveSelection || model.isStorageExplorerMeasurementBlocked)
            .help(
                explorer.canRemoveSelection
                    ? "Review the selected items before they move to the Trash."
                    : "Select only unlocked items to continue."
            )

        case .uninstaller, .history:
            EmptyView()

        case .trash:
            Button("Empty Trash") { model.activeSheet = .emptyTrash }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Token.color(.red))
                // Keep the destructive action in its stable footer position while
                // the Trash is loading or empty, but do not open an empty review.
                .disabled((model.trashSummary?.itemCount ?? 0) == 0 || model.activity != nil)

        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The pair is one HStack inside the group, with the rule drawn between the
        // arrows the way Finder's back/forward control does.
        //
        // Not `ControlGroup`: it renders the separator correctly but loses the
        // leading edge — the pair drifts to the right of the title. A bare
        // `ToolbarItemGroup` holds the left but draws no separator, so the rule is
        // placed by hand.
        // No leading inset item: the toolbar's own ~4.5pt is matched by the content's
        // horizontal padding instead. Insetting the toolbar proved impossible —
        // `ToolbarSpacer(.fixed)` adds nothing visible, and a `Color.clear` inside
        // the group is swallowed by its shared capsule, padding the first chevron.

        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)

                Rectangle()
                    .fill(Token.separator)
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)

                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
            }
        }

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

        ToolbarItem(placement: .primaryAction) {
            // The button supplies the Liquid Glass surface. Hide the toolbar
            // item's shared background so a second capsule does not appear.
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
            .buttonStyle(.glassProminent)
            // Large, like the App Store's offer button: a filled capsule at
            // regular size read as an afterthought next to the 52pt bar.
            .controlSize(.large)
            .disabled(model.isBusyWithDisk)
            .help("Scan for reclaimable files")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}
