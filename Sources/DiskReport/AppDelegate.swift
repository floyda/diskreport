import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if CommandLine.arguments.contains("--show-report") { showReport() }
    }

    /// `open -a DiskReport` on a running instance lands here; launchd uses that after each scan.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReport()
        return false
    }

    func showReport() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DiskReport"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("DiskReportReportWindow")
            w.contentView = NSHostingView(rootView: ReportWindowView().environmentObject(model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
