import Foundation

public extension Store {
    /// All scans for a root, newest started first.
    func scans(rootID: Int64) throws -> [ScanRecord] {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? ORDER BY started_at DESC, id DESC").bind(1, rootID)
        var out: [ScanRecord] = []
        while try q.step() { out.append(Store.readScan(q)) }
        return out
    }

    func latestScan(rootID: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? ORDER BY started_at DESC, id DESC LIMIT 1").bind(1, rootID)
        return try q.step() ? Store.readScan(q) : nil
    }

    func latestCompletedScan(rootID: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? AND status = 'completed' ORDER BY finished_at DESC, id DESC LIMIT 1").bind(1, rootID)
        return try q.step() ? Store.readScan(q) : nil
    }

    /// Latest completed scan with finished_at <= the given time. Nil when none exists (report shows "no data").
    func baselineScan(rootID: Int64, finishedAtOrBefore cutoff: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE root_id = ? AND status = 'completed' AND finished_at <= ? ORDER BY finished_at DESC, id DESC LIMIT 1")
            .bind(1, rootID).bind(2, cutoff)
        return try q.step() ? Store.readScan(q) : nil
    }

    func dirStats(scanID: Int64) throws -> [DirStat] {
        let q = try db.prepare("SELECT path, parent_path, depth, bytes, file_count, newest_mtime, kind FROM dir_stats WHERE scan_id = ? ORDER BY path").bind(1, scanID)
        var out: [DirStat] = []
        while try q.step() {
            out.append(DirStat(path: q.text(0), parentPath: q.optionalText(1), depth: Int(q.int64(2)), bytes: q.int64(3),
                               fileCount: q.int64(4), newestMtime: q.int64(5), kind: q.optionalText(6)))
        }
        return out
    }

    func deleteScans(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let del = try db.prepare("DELETE FROM scans WHERE id = ?")
            for id in ids {
                del.reset()
                try del.bind(1, id).run()
            }
        }
    }
}
