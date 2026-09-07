public enum Delta: Equatable, Sendable {
    case noData
    case new(Int64)
    case changed(Int64)

    public var bytes: Int64? {
        switch self {
        case .noData: return nil
        case .new(let b), .changed(let b): return b
        }
    }
}

public struct ReportRow: Equatable, Sendable {
    public var path: String
    public var parentPath: String?
    public var depth: Int
    public var bytes: Int64
    public var fileCount: Int64
    public var newestMtime: Int64
    public var kind: String?
    public var deltas: [Window: Delta]
    public var isDeleted: Bool

    public init(path: String, parentPath: String?, depth: Int, bytes: Int64, fileCount: Int64, newestMtime: Int64,
                kind: String?, deltas: [Window: Delta], isDeleted: Bool) {
        self.path = path
        self.parentPath = parentPath
        self.depth = depth
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestMtime = newestMtime
        self.kind = kind
        self.deltas = deltas
        self.isDeleted = isDeleted
    }
}

public enum ReportBuilder {
    /// Joins the current scan against per-window baselines. Missing window ⇒ `.noData`.
    /// Deleted rows are derived from the day baseline only, and only when their parent still exists.
    public static func rows(current: [DirStat], baselines: [Window: [DirStat]]) -> [ReportRow] {
        let baselineBytes: [Window: [String: Int64]] = baselines.mapValues { stats in
            var m: [String: Int64] = [:]
            m.reserveCapacity(stats.count)
            for s in stats { m[s.path] = s.bytes }
            return m
        }
        let currentPaths = Set(current.map(\.path))

        var rows: [ReportRow] = []
        rows.reserveCapacity(current.count)
        for s in current {
            var deltas: [Window: Delta] = [:]
            for w in Window.allCases {
                guard let base = baselineBytes[w] else { deltas[w] = .noData; continue }
                if let b = base[s.path] { deltas[w] = .changed(s.bytes - b) } else { deltas[w] = .new(s.bytes) }
            }
            rows.append(ReportRow(path: s.path, parentPath: s.parentPath, depth: s.depth, bytes: s.bytes,
                                  fileCount: s.fileCount, newestMtime: s.newestMtime, kind: s.kind,
                                  deltas: deltas, isDeleted: false))
        }

        if let dayBaseline = baselines[.day] {
            for b in dayBaseline where !currentPaths.contains(b.path) {
                guard let parent = b.parentPath, currentPaths.contains(parent) else { continue }
                rows.append(ReportRow(path: b.path, parentPath: parent, depth: b.depth, bytes: b.bytes,
                                      fileCount: b.fileCount, newestMtime: b.newestMtime, kind: b.kind,
                                      deltas: [.day: .changed(-b.bytes), .week: .noData, .month: .noData],
                                      isDeleted: true))
            }
        }
        return rows
    }
}
