import AppKit
import MacCleanerCore
import SwiftUI

/// Reviews files that match by size, hashes, and a final byte comparison.
struct FileDuplicatesView: View {
    @Bindable var model: AppModel

    private let minimumOptions: [(String, Int64)] = [
        ("All files (0 MB)", 0),
        ("At least 1 MB", 1_000_000),
        ("At least 10 MB", 10_000_000),
        ("At least 100 MB", 100_000_000)
    ]

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
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Find duplicate files", systemImage: "doc.on.doc")
        } description: {
            // The skips are said up front. "Package" means nothing to most people,
            // and Pages, Numbers and Keynote documents are packages — a duplicate
            // scan that is silent about them reads as having checked them.
            Text("Select one or more folders. MacCleaner verifies file contents and keeps "
                 + "one copy in each set. Hidden files, cloud-only files and documents saved "
                 + "as packages, such as Pages and Keynote files, are not compared.")
        } actions: {
            scanControls(buttonLabel: "Choose Folders")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            if let progress = model.fileDuplicateProgress, progress.total > 0 {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .frame(width: 280)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }

            Text(progressLabel)
                .font(.mcBody)
                .foregroundStyle(Token.Text.secondary)

            Button("Stop") { model.cancelFileDuplicateScan() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 110)
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

    private var nothingFound: some View {
        ContentUnavailableView {
            Label("No duplicate files found", systemImage: "checkmark.circle")
        } description: {
            if let results = model.fileDuplicateResults {
                Text(resultSummary(results))
            }
        } actions: {
            scanControls(buttonLabel: "Choose Other Folders")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var groups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let results = model.fileDuplicateResults {
                        Text(resultSummary(results))
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.Text.secondary)
                    }
                    Spacer()
                    minimumPicker
                    Button("Scan Again") { model.startFileDuplicateScan() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isBusyWithDisk)
                    Button("Choose Other Folders") { model.chooseFileDuplicateFolders() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isBusyWithDisk)
                }
                .padding(.horizontal, 2)

                ForEach(model.fileDuplicateGroups) { group in
                    groupCard(group)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func scanControls(buttonLabel: String) -> some View {
        HStack(spacing: 10) {
            minimumPicker

            Button { model.chooseFileDuplicateFolders() } label: {
                Text(buttonLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.isBusyWithDisk)
        }
    }

    private var minimumPicker: some View {
        Picker("Minimum file size", selection: $model.fileDuplicateMinimumBytes) {
            ForEach(minimumOptions, id: \.1) { option in
                Text(option.0).tag(option.1)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Set zero to check all files. Small files make the scan slower.")
    }

    private func resultSummary(_ results: FileDuplicateResults) -> String {
        var text = "Checked \(results.examinedCount.formatted()) files. "
            + "\(results.eligibleCount.formatted()) met the minimum size."
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
                    Badge(text: "verified", style: .safe)
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
                Button { model.toggleFileDuplicate(file.id) } label: {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Color.accentColor : Token.Text.tertiary)
                }
                .buttonStyle(.plain)
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
