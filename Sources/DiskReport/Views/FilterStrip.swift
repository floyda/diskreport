import DiskReportUI
import SwiftUI

struct FilterStrip: View {
    @ObservedObject var viewModel: ReportViewModel

    var body: some View {
        HStack {
            Picker("Filter", selection: $viewModel.filter) {
                ForEach(QuickFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
            TextField("Search path", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
