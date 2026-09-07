import DiskReportCore
@testable import DiskReportUI

enum Fx {
    static let day: Int64 = 86_400
    static let now: Int64 = 1_800_000_000

    static func row(_ path: String, bytes: Int64 = 10, files: Int64 = 1, mtime: Int64 = now,
                    day: Delta = .noData, week: Delta = .noData, month: Delta = .noData,
                    deleted: Bool = false, kind: String? = nil) -> ReportRow {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        let depth = max(0, comps.count - 1)
        let parent = depth == 0 ? nil : "/" + comps.dropLast().joined(separator: "/")
        return ReportRow(path: path, parentPath: parent, depth: depth, bytes: bytes, fileCount: files, newestMtime: mtime,
                         kind: kind, deltas: [.day: day, .week: week, .month: month], isDeleted: deleted)
    }

    static func report(_ rootPath: String, rows: [ReportRow]) -> RootReport {
        let current = ScanRecord(id: 1, rootID: 1, startedAt: now - 60, finishedAt: now, status: .completed, totalBytes: rows.first?.bytes)
        return RootReport(rootID: 1, rootPath: rootPath, current: current, latest: current, baselines: [:], rows: rows)
    }

    /// A tree 5 levels deep: /w, /w/a, /w/a/b, /w/a/b/c, /w/a/b/c/d, plus /w/x.
    static func deepReport() -> RootReport {
        report("/w", rows: [
            row("/w", bytes: 100), row("/w/a", bytes: 60), row("/w/a/b", bytes: 50), row("/w/a/b/c", bytes: 40),
            row("/w/a/b/c/d", bytes: 30), row("/w/x", bytes: 40),
        ])
    }
}
