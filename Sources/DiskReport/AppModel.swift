import Combine
import DiskReportCore
import DiskReportUI
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var reports: [RootReport] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isLoading = false
    @Published var scanRunnerError: String?
    @Published private(set) var lastLoaded: Date?

    let viewModel = ReportViewModel()
    let paths = DataPaths.standard()
    private let evaluator = NotableEvaluator(rules: [])
    private var watcher: DatabaseWatcher?
    private var runner: ScanRunner?

    var summary: ReportSummary { ReportSummary.from(reports) }
    var hasNotices: Bool { !evaluator.notices(for: summary).isEmpty }

    var headline: String {
        guard let current = reports.compactMap(\.current).first, let finished = current.finishedAt else {
            return "No completed scan yet"
        }
        let when = Date(timeIntervalSince1970: TimeInterval(finished))
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        var text = "Last scan: \(f.string(from: when))"
        if let free = current.volumeFreeBytes { text += " · \(ByteFormatter.string(free)) free" }
        return text
    }

    func start() {
        reload()
        let watcher = DatabaseWatcher(directory: paths.dataDir, fileName: paths.databaseURL.lastPathComponent) { [weak self] in
            self?.reload()
        }
        watcher.start()
        self.watcher = watcher
    }

    func reload() {
        let dbURL = paths.databaseURL
        isLoading = true
        Task {
            let loaded: [RootReport] = await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
                do {
                    let store = try Store(url: dbURL)
                    return try ReportLoader.loadRootReports(store: store)
                } catch {
                    NSLog("DiskReport: load failed: \(error)")
                    return []
                }
            }.value
            self.reports = loaded
            self.viewModel.load(reports: loaded, now: Int64(Date().timeIntervalSince1970))
            self.lastLoaded = Date()
            self.isLoading = false
        }
    }

    func scanNow() {
        guard !isScanning else { return }
        isScanning = true
        scanRunnerError = nil
        let runner = ScanRunner(paths: paths)
        self.runner = runner
        runner.run { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isScanning = false
                if case .failure(let error) = result { self.scanRunnerError = error.localizedDescription }
                self.reload()
            }
        }
    }
}
