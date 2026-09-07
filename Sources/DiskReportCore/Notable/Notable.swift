public struct RootSummary: Equatable, Sendable {
    public var rootPath: String
    public var totalBytes: Int64
    public var deltaDay: Int64?
    public init(rootPath: String, totalBytes: Int64, deltaDay: Int64?) {
        self.rootPath = rootPath
        self.totalBytes = totalBytes
        self.deltaDay = deltaDay
    }
}

/// Compact view of the latest report for rule evaluation and the summary bar.
public struct ReportSummary: Equatable, Sendable {
    public var volumeFreeBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var volumeFreeDeltaDay: Int64?
    public var roots: [RootSummary]

    public init(volumeFreeBytes: Int64?, volumeTotalBytes: Int64?, volumeFreeDeltaDay: Int64?, roots: [RootSummary]) {
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeFreeDeltaDay = volumeFreeDeltaDay
        self.roots = roots
    }

    public static func from(_ reports: [RootReport]) -> ReportSummary {
        let firstCurrent = reports.compactMap(\.current).first
        let firstWithDay = reports.first { $0.current != nil && $0.baselines[.day] != nil }
        var freeDelta: Int64?
        if let r = firstWithDay, let now = r.current?.volumeFreeBytes, let then = r.baselines[.day]?.volumeFreeBytes {
            freeDelta = now - then
        }
        let roots = reports.map { r -> RootSummary in
            let total = r.current?.totalBytes ?? 0
            var delta: Int64?
            if let cur = r.current?.totalBytes, let base = r.baselines[.day]?.totalBytes { delta = cur - base }
            return RootSummary(rootPath: r.rootPath, totalBytes: total, deltaDay: delta)
        }
        return ReportSummary(volumeFreeBytes: firstCurrent?.volumeFreeBytes, volumeTotalBytes: firstCurrent?.volumeTotalBytes,
                             volumeFreeDeltaDay: freeDelta, roots: roots)
    }
}

public struct Notice: Equatable, Sendable {
    public var title: String
    public var detail: String
    public init(title: String, detail: String) { self.title = title; self.detail = detail }
}

/// Extension point for "something to notify about". v1 ships no rules.
public protocol NotableRule: Sendable {
    func evaluate(_ summary: ReportSummary) -> Notice?
}

public struct NotableEvaluator: Sendable {
    public var rules: [NotableRule]
    public init(rules: [NotableRule] = []) { self.rules = rules }

    public func notices(for summary: ReportSummary) -> [Notice] {
        rules.compactMap { $0.evaluate(summary) }
    }
}
