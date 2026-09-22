import AppKit
import ScoloCore
import SwiftUI

/// Reviews files that match by size, hashes, and a final byte comparison.
struct FileDuplicatesView: View {
    @Bindable var model: AppModel
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?

    var body: some View {
        Group {
            if model.isScanningDuplicateFiles {
                scanning
            } else if model.fileDuplicateResults == nil {
                intro
            } else if model.fileDuplicateGroups.isEmpty {
                nothingFound
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .operationResultAnimation(isRunning: model.isScanningDuplicateFiles)
        .onChange(of: model.isScanningDuplicateFiles, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.fileDuplicateResults?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.fileDuplicateResults?.finishedAt != nil
                    && model.fileDuplicateResults?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.fileDuplicateMinimumBytes) { _, _ in animateEmptyResult = false }
        .onDisappear { animateEmptyResult = false }
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Find duplicate files", systemImage: "doc.on.doc")
        } description: {
            // The skips are said up front. "Package" means nothing to most people,
            // and Pages, Numbers and Keynote documents are packages — a duplicate
            // scan that is silent about them reads as having checked them.
            Text("Select one or more folders. Scolo verifies file contents and keeps "
                 + "one copy in each set. Hidden files, cloud-only files and documents saved "
                 + "as packages, such as Pages and Keynote files, are not compared.")
        } actions: {
            scanControls(buttonLabel: "Choose Folders")
        }
        .pageStateLayout()
    }

    private var scanning: some View {
        ScanProgressPage {
            intro
        } progress: { actionBottom in
            PageProgressView(
                title: "Scanning for duplicate files",
                detail: progressLabel,
                progress: model.fileDuplicateProgress.flatMap {
                    $0.total > 0 ? Double($0.completed) / Double($0.total) : nil
                },
                onStop: { model.cancelFileDuplicateScan() },
                actionBottom: actionBottom
            )
        }
    }

    private var progressLabel: String {
        guard let progress = model.fileDuplicateProgress else { return "Preparing…" }
        switch progress.stage {
        case .enumerating:
            return "Reading the selected folders…"
        case .sampling:
            return "Checking likely matches — \(progress.completed) of \(progress.total)"
        case .verifying:
            return "Verifying file contents — \(progress.completed) of \(progress.total)"
        case .done:
            return "Finishing…"
        }
    }

    @ViewBuilder
    private var nothingFound: some View {
        if hasFilteredResults {
            ContentUnavailableView {
                Label("No duplicates match this size", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Choose a smaller minimum file size to show more results.")
            }
            .operationPageLayout()
        } else {
            ScanCompletionView(
                title: "No duplicate files found",
                detail: model.fileDuplicateResults.map { resultSummary($0) },
                animate: animateEmptyResult
            )
        }
    }

    private var hasFilteredResults: Bool {
        !(model.fileDuplicateResults?.groups.isEmpty ?? true)
    }

    private var groups: some View {
        let selectable = Set(model.fileDuplicateGroups.flatMap(\.removable).map(\.id))
        return VStack(spacing: 0) {
            HStack {
                MonochromeCheckbox(
                    title: "Select All",
                    detail: "\(selectable.count) \(selectable.count == 1 ? "item" : "items")",
                    state: !selectable.isEmpty && selectable.isSubset(of: model.fileDuplicateSelection) ? .on : .off,
                    isEnabled: !selectable.isEmpty && !model.isBusyWithDisk
                ) { isOn in
                    if isOn { model.selectAllFileDuplicates() }
                    else { model.deselectAllFileDuplicates() }
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, Token.Size.pageGutter + 15)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .help(model.fileDuplicateResults.map { resultSummary($0) } ?? "")

            scrollingGroups
        }
    }

    private var scrollingGroups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.fileDuplicateGroups) { group in
                    groupCard(group)
                }
            }
            .padding(.horizontal, Token.Size.pageGutter)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func scanControls(buttonLabel: String) -> some View {
        HStack(spacing: 10) {
            FileDuplicateMinimumPicker(model: model)

            Button { model.chooseFileDuplicateFolders() } label: {
                Text(buttonLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
            }
                .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                .controlSize(.large)
                .fixedSize(horizontal: true, vertical: false)
                .scanActionAnchor()
                .disabled(model.isBusyWithDisk)
        }
    }

    private func resultSummary(_ results: FileDuplicateResults) -> String {
        var text = "Checked \(results.examinedCount.formatted()) files. "
            + "\(results.eligibleCount.formatted()) were eligible for comparison."
        if !results.groups.isEmpty {
            text += " Found \(results.groups.count.formatted()) verified duplicate sets."
        }
        if results.skippedCount > 0 {
            text += " Skipped \(results.skippedCount.formatted()) unreadable, changed, or cloud-only items."
        }
        return text
    }

    private func groupCard(_ group: FileDuplicateGroup) -> some View {
        GroupedBox {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(group.count) identical files · keeping 1")
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text("(\(group.keeperReason.label))")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Up to \(ByteFormatting.string(group.reclaimableBytes)) available")
                            .font(.mcRowValue.weight(.medium))
                            .foregroundStyle(Token.Text.primary)
                        Text("APFS clones can share storage")
                            .font(.mcCaption)
                            .foregroundStyle(Token.Text.tertiary)
                    }
                    Button(groupIsSelected(group) ? "Deselect" : "Select Copies") {
                        model.toggleFileDuplicateGroup(group)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(12)

                Divider()

                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, group: group)
                    if index < group.files.count - 1 { Divider().padding(.leading, 48) }
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, group: FileDuplicateGroup) -> some View {
        let isKeeper = file.id == group.keeper.id
        let selected = model.fileDuplicateSelection.contains(file.id)

        return HStack(spacing: 10) {
            if isKeeper {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Token.textColor(.green))
                    .frame(width: 28, height: 28)
                    .help("This copy will remain")
            } else {
                MonochromeCheckbox(
                    title: "Select \(file.url.lastPathComponent)",
                    state: selected ? .on : .off,
                    isEnabled: !model.isBusyWithDisk,
                    showsTitle: false
                ) { _ in model.toggleFileDuplicate(file.id) }
                .frame(width: 28, height: 28)
                .help(selected ? "Keep this copy" : "Move this copy to the Trash")
            }

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.url.lastPathComponent)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                    if isKeeper { Badge(text: "keep", style: .safe) }
                }
                Text(
                    (file.url.deletingLastPathComponent().path as NSString)
                        .abbreviatingWithTildeInPath
                )
                    .font(.mcCaption.monospaced())
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if let date = file.modificationDate {
                Text(date, format: .dateTime.day().month().year())
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
            }

            // Allocated, like the set's "Up to" figure above it, so the rows add up
            // to the header. Logical size differs for compressed files.
            Text(ByteFormatting.string(file.allocatedBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.primary)
                .frame(width: 84, alignment: .trailing)
                .help("Space on disk")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .contentShape(Rectangle())
        .contextMenu {
            if !isKeeper {
                Button("Keep This Copy") {
                    model.keepFileInstead(groupID: group.id, fileID: file.id)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

    private func groupIsSelected(_ group: FileDuplicateGroup) -> Bool {
        !group.removable.isEmpty && group.removable.allSatisfy {
            model.fileDuplicateSelection.contains($0.id)
        }
    }
}

/// Uses the same file size menu before and after a scan.
struct FileDuplicateMinimumPicker: View {
    @Bindable var model: AppModel

    private let minimumOptions: [(String, Int64)] = [
        ("All files (0 MB)", 0),
        ("At least 1 MB", 1_000_000),
        ("At least 10 MB", 10_000_000),
        ("At least 100 MB", 100_000_000)
    ]

    var body: some View {
        HStack(spacing: 8) {
            Text("Minimum file size")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
            Menu {
                Picker("Minimum file size", selection: $model.fileDuplicateMinimumBytes) {
                    ForEach(minimumOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 7) {
                    Text(minimumOptions.first { $0.1 == model.fileDuplicateMinimumBytes }?.0
                         ?? ByteFormatting.string(model.fileDuplicateMinimumBytes))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.button)
            .buttonStyle(PageActionButtonStyle())
            .menuIndicator(.hidden)
            .disabled(model.isBusyWithDisk)
            .accessibilityLabel("Minimum file size")
            .accessibilityValue(minimumOptions.first { $0.1 == model.fileDuplicateMinimumBytes }?.0 ?? "")
        }
        .fixedSize()
        .help("Filter results by file size. The scan checks all eligible file sizes.")
    }

}
