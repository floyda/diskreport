import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    let showReport: () -> Void

    var body: some View {
        Text(model.headline)
        Divider()
        Button("Open Report") { showReport() }.keyboardShortcut("o")
        Button(model.isScanning ? "Scanning…" : "Scan Now") { model.scanNow() }
            .disabled(model.isScanning)
            .keyboardShortcut("s")
        Button("Reveal Database in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.databaseURL])
        }
        Divider()
        Button("Quit DiskReport") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
