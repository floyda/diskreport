import SwiftUI

struct ReportWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar(model: model)
            Divider()
            FilterStrip(viewModel: model.viewModel)
            Divider()
            ReportTable(viewModel: model.viewModel)
        }
        .frame(minWidth: 900, minHeight: 500)
    }
}
