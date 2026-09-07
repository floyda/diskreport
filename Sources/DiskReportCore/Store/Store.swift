import Foundation

public struct RootEntry: Equatable, Sendable {
    public var id: Int64
    public var path: String
    public init(id: Int64, path: String) { self.id = id; self.path = path }
}

/// The only component that writes to disk (besides Logging). Owns the SQLite database.
public final class Store {
    let db: Database

    public init(url: URL) throws {
        db = try Database(path: url.path)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("PRAGMA temp_store=MEMORY")
        try db.exec("PRAGMA foreign_keys=ON")
        try db.exec(Store.schemaV1)
    }

    static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS roots (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS scans (
      id INTEGER PRIMARY KEY,
      root_id INTEGER NOT NULL REFERENCES roots(id),
      started_at INTEGER NOT NULL,
      finished_at INTEGER,
      status TEXT NOT NULL,
      total_bytes INTEGER,
      file_count INTEGER,
      dir_count INTEGER,
      volume_free_bytes INTEGER,
      volume_total_bytes INTEGER,
      skipped_count INTEGER,
      error TEXT
    );
    CREATE INDEX IF NOT EXISTS scans_root_finished ON scans(root_id, status, finished_at);
    CREATE TABLE IF NOT EXISTS dir_stats (
      scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
      path TEXT NOT NULL,
      parent_path TEXT,
      depth INTEGER NOT NULL,
      bytes INTEGER NOT NULL,
      file_count INTEGER NOT NULL,
      newest_mtime INTEGER NOT NULL,
      kind TEXT,
      PRIMARY KEY (scan_id, path)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS dir_stats_parent ON dir_stats(scan_id, parent_path);
    """

    // MARK: Roots

    public func rootID(for path: String) throws -> Int64 {
        try db.prepare("INSERT OR IGNORE INTO roots(path) VALUES (?)").bind(1, path).run()
        let q = try db.prepare("SELECT id FROM roots WHERE path = ?").bind(1, path)
        guard try q.step() else { throw DatabaseError.step(sql: "rootID", message: "missing after insert") }
        return q.int64(0)
    }

    public func roots() throws -> [RootEntry] {
        let q = try db.prepare("SELECT id, path FROM roots ORDER BY id")
        var out: [RootEntry] = []
        while try q.step() { out.append(RootEntry(id: q.int64(0), path: q.text(1))) }
        return out
    }

    // MARK: Scan writes

    public func beginScan(rootID: Int64, startedAt: Int64) throws -> Int64 {
        try db.prepare("INSERT INTO scans(root_id, started_at, status) VALUES (?, ?, 'running')")
            .bind(1, rootID).bind(2, startedAt).run()
        return db.lastInsertRowID
    }

    public func insertDirStats(scanID: Int64, _ stats: [DirStat]) throws {
        try db.transaction {
            let ins = try db.prepare("""
                INSERT INTO dir_stats(scan_id, path, parent_path, depth, bytes, file_count, newest_mtime, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for s in stats {
                ins.reset()
                try ins.bind(1, scanID).bind(2, s.path).bind(3, s.parentPath).bind(4, Int64(s.depth))
                    .bind(5, s.bytes).bind(6, s.fileCount).bind(7, s.newestMtime).bind(8, s.kind).run()
            }
        }
    }

    public func completeScan(id: Int64, finishedAt: Int64, summary: ScanSummary) throws {
        try db.prepare("""
            UPDATE scans SET finished_at = ?, status = 'completed', total_bytes = ?, file_count = ?, dir_count = ?,
              volume_free_bytes = ?, volume_total_bytes = ?, skipped_count = ?, error = NULL WHERE id = ?
            """)
            .bind(1, finishedAt).bind(2, summary.totalBytes).bind(3, summary.fileCount).bind(4, summary.dirCount)
            .bind(5, summary.volumeFreeBytes).bind(6, summary.volumeTotalBytes).bind(7, summary.skippedCount)
            .bind(8, id).run()
    }

    public func failScan(id: Int64, finishedAt: Int64, error: String) throws {
        try db.prepare("UPDATE scans SET finished_at = ?, status = 'failed', error = ? WHERE id = ?")
            .bind(1, finishedAt).bind(2, error).bind(3, id).run()
    }

    /// Marks every 'running' scan as failed. Safe because the lock file guarantees no other scanner is live.
    @discardableResult
    public func failStaleRunningScans(now: Int64) throws -> Int {
        try db.prepare("UPDATE scans SET finished_at = ?, status = 'failed', error = 'interrupted' WHERE status = 'running'")
            .bind(1, now).run()
        return db.changes
    }

    // MARK: Basic reads (more in Queries via extension in Task 5)

    public func scan(id: Int64) throws -> ScanRecord? {
        let q = try db.prepare(Store.scanSelect + " WHERE id = ?").bind(1, id)
        return try q.step() ? Store.readScan(q) : nil
    }

    public func dirStatCount(scanID: Int64) throws -> Int {
        let q = try db.prepare("SELECT COUNT(*) FROM dir_stats WHERE scan_id = ?").bind(1, scanID)
        _ = try q.step()
        return Int(q.int64(0))
    }

    static let scanSelect = """
        SELECT id, root_id, started_at, finished_at, status, total_bytes, file_count, dir_count,
               volume_free_bytes, volume_total_bytes, skipped_count, error FROM scans
        """

    static func readScan(_ q: Statement) -> ScanRecord {
        ScanRecord(id: q.int64(0), rootID: q.int64(1), startedAt: q.int64(2), finishedAt: q.optionalInt64(3),
                   status: ScanStatus(rawValue: q.text(4)) ?? .failed,
                   totalBytes: q.optionalInt64(5), fileCount: q.optionalInt64(6), dirCount: q.optionalInt64(7),
                   volumeFreeBytes: q.optionalInt64(8), volumeTotalBytes: q.optionalInt64(9),
                   skippedCount: q.optionalInt64(10), error: q.optionalText(11))
    }
}
