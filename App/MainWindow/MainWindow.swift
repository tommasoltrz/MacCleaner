import SwiftUI
import MacCleanerCore

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
        .task { await model.loadDashboard() }
        // Coming back to the app is the moment stale rows show: the user was just
        // in Finder, doing things this snapshot cannot know about.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.pruneVanishedEntries() }
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
            case .large:
                LargeFilesView(model: model)
            case .trash:
                TrashView(model: model)
            case .photos:
                PhotoDuplicatesView(model: model)
            case .safeToRemove:
                FilteredEntriesView(model: model, filter: .safeToRemove)
            case .needsReview:
                FilteredEntriesView(model: model, filter: .needsReview)
            }
        }
        .frame(minWidth: Token.Size.minimumContentWidth)
        .background(Token.pageBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView(message: model.statusMessage) {
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
            // The Dashboard shows cached figures on launch rather than re-walking the
            // disk (and re-triggering folder permission prompts) every time, so it
            // needs an explicit way to refresh them.
            Button(model.isLoadingBreakdown ? "Measuring…" : "Measure Again") {
                Task { await model.measureStorage() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isLoadingBreakdown)

        case .scanner, .large, .safeToRemove, .needsReview:
            // The tile drill-downs promise a sweep — "safe to remove" especially —
            // and a sweep should not mean ticking every row by hand. It sits beside
            // Deselect All rather than up in the header, where the two halves of
            // one decision were a window apart. The Scanner and Large & Old Files
            // are browsing views with their own per-category controls, so they keep
            // Deselect All alone.
            if model.view == .safeToRemove || model.view == .needsReview {
                Button("Select All") { model.selectAllInCurrentView() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!model.canSelectAllInCurrentView)
            }

            Button("Deselect All") { model.deselectAll() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.hasSelection)

            Button(model.cleanUpLabel) { model.requestCleanUp() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                // Nothing selected means nothing to confirm; the design renders the
                // button inert rather than hiding it, so its place stays predictable.
                .disabled(!model.hasSelection)
        case .photos:
            Button("Select All") { model.selectAllRemovablePhotos() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.photoGroups.isEmpty)

            // The one-click retreat from the judgement calls: everything the sweep is
            // certain about stays ticked, the "Looks similar" groups come off.
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

        default:
            EmptyView()
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

        if model.isScanning {
            ToolbarItem(placement: .principal) {
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

        ToolbarItem(placement: .primaryAction) {
            // The button is the whole toolbar item. It used to sit between two
            // clear 14pt spacers for inset, but the toolbar absorbed those into
            // the item's glass capsule — a capsule wider than the button, whose
            // hover highlight then lit only the inner part. The inset the spacers
            // provided comes from the wider label padding below instead, so the
            // capsule, the hover region and the button are one and the same.
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
            .buttonStyle(.borderedProminent)
            // Large, like the App Store's offer button: a filled capsule at
            // regular size read as an afterthought next to the 52pt bar.
            .controlSize(.large)
            .disabled(model.isScanning)
            .help("Scan for reclaimable files")
        }
    }
}
