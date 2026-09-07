import SwiftUI

@main
struct DiskReportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model, showReport: { delegate.showReport() })
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.hasNotices ? "externaldrive.badge.exclamationmark" : "externaldrive")
    }
}
