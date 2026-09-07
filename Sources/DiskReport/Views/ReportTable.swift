import AppKit
import DiskReportCore
import DiskReportUI
import SwiftUI

struct ReportTable: View {
    @ObservedObject var viewModel: ReportViewModel
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<VisibleRow>] = [KeyPathComparator(\VisibleRow.name)]

    var body: some View {
        Table(viewModel.visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                NameCell(row: row) { viewModel.toggle(row.id) }
            }
            .width(min: 280, ideal: 420)

            TableColumn("Size", value: \.bytes) { row in
                Text(ByteFormatter.string(row.bytes)).monospacedDigit()
            }
            .width(90)

            TableColumn("Δ Day", value: \.deltaDaySort) { row in DeltaCell(delta: row.deltaDay) }.width(110)
            TableColumn("Δ Week", value: \.deltaWeekSort) { row in DeltaCell(delta: row.deltaWeek) }.width(110)
            TableColumn("Δ Month", value: \.deltaMonthSort) { row in DeltaCell(delta: row.deltaMonth) }.width(110)

            TableColumn("Last Modified", value: \.newestMtime) { row in
                Text(DateFormatting.relative(mtime: row.newestMtime, now: viewModel.now))
                    .help(DateFormatting.absolute(row.newestMtime))
            }
            .width(120)

            TableColumn("Files", value: \.fileCount) { row in
                Text("\(row.fileCount)").monospacedDigit()
            }
            .width(80)
        }
        .onChange(of: sortOrder) { _, newValue in
            guard let first = newValue.first, let key = SortKey(keyPath: first.keyPath) else { return }
            viewModel.setSort(key: key, ascending: first.order == .forward)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Expand") { viewModel.expand(ids) }
            Button("Collapse") { viewModel.collapse(ids) }
            Divider()
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Path") { copyPaths(ids) }
            Button("Open in Terminal") { openInTerminal(ids) }
        } primaryAction: { ids in
            reveal(ids)
        }
        .onKeyPress(.rightArrow) { viewModel.expand(selection); return .handled }
        .onKeyPress(.leftArrow) { viewModel.collapse(selection); return .handled }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(selection.isEmpty ? "Select a folder" : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Path") { copyPaths(selection) }.disabled(selection.isEmpty)
                Button("Open in Terminal") { openInTerminal(selection) }.disabled(selection.isEmpty)
                Button("Reveal in Finder") { reveal(selection) }
                    .disabled(selection.isEmpty)
                    .keyboardShortcut("r")
                    .buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(.bar)
        }
    }

    /// Finder opens the parent folder with each target selected, so ⌘⌫ acts on it directly.
    private func reveal(_ ids: Set<String>) {
        let urls = ids.map(RevealTarget.url(forFolder:))
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ids.sorted().joined(separator: "\n"), forType: .string)
    }

    private func openInTerminal(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let urls = ids.map { URL(fileURLWithPath: $0, isDirectory: true) }
        NSWorkspace.shared.open(urls, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct NameCell: View {
    let row: VisibleRow
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * 16)
            if row.hasChildren {
                Button(action: toggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.isExpanded ? "Collapse" : "Expand")
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: "folder").foregroundStyle(row.isDeleted ? Color.secondary : Color.accentColor)
            Text(row.name)
                .strikethrough(row.isDeleted)
                .foregroundStyle(row.isDeleted ? .secondary : .primary)
                .lineLimit(1)
                .help(row.id)
        }
    }
}

private struct DeltaCell: View {
    let delta: Delta

    var body: some View {
        let bytes = delta.bytes ?? 0
        Text(DeltaFormatter.string(delta))
            .monospacedDigit()
            .foregroundStyle(delta.bytes == nil ? Color.secondary : (bytes > 0 ? Color.red : (bytes < 0 ? Color.green : Color.secondary)))
    }
}
