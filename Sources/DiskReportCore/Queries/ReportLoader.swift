public struct RootReport: Sendable {
    public var rootID: Int64
    public var rootPath: String
    /// Latest completed scan, the one the rows describe.
    public var current: ScanRecord?
    /// Latest scan of any status, used for banners ("last scan failed", "scanning").
    public var latest: ScanRecord?
    public var baselines: [Window: ScanRecord]
    public var rows: [ReportRow]

    public init(rootID: Int64, rootPath: String, current: ScanRecord?, latest: ScanRecord?,
                baselines: [Window: ScanRecord], rows: [ReportRow]) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.current = current
        self.latest = latest
        self.baselines = baselines
        self.rows = rows
    }
}

public enum ReportLoader {
    public static func loadRootReports(store: Store) throws -> [RootReport] {
        try store.roots().map { root in
            let latest = try store.latestScan(rootID: root.id)
            guard let current = try store.latestCompletedScan(rootID: root.id), let finished = current.finishedAt else {
                return RootReport(rootID: root.id, rootPath: root.path, current: nil, latest: latest, baselines: [:], rows: [])
            }
            var baselines: [Window: ScanRecord] = [:]
            var baselineStats: [Window: [DirStat]] = [:]
            var statsByScan: [Int64: [DirStat]] = [:]
            for w in Window.allCases {
                let cutoff = w.baselineCutoff(currentFinishedAt: finished)
                guard let b = try store.baselineScan(rootID: root.id, finishedAtOrBefore: cutoff) else { continue }
                baselines[w] = b
                if statsByScan[b.id] == nil { statsByScan[b.id] = try store.dirStats(scanID: b.id) }
                baselineStats[w] = statsByScan[b.id]
            }
            let rows = ReportBuilder.rows(current: try store.dirStats(scanID: current.id), baselines: baselineStats)
            return RootReport(rootID: root.id, rootPath: root.path, current: current, latest: latest,
                              baselines: baselines, rows: rows)
        }
    }
}
