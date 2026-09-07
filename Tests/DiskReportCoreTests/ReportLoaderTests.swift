import XCTest
@testable import DiskReportCore

final class ReportLoaderTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!
    private let day: Int64 = 86_400
    private let t0: Int64 = 1_800_000_000

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("l.sqlite")))
    }

    private func complete(rootID: Int64, finishedAt: Int64, stats: [DirStat], totalBytes: Int64) throws -> Int64 {
        let id = try store.beginScan(rootID: rootID, startedAt: finishedAt - 60)
        try store.insertDirStats(scanID: id, stats)
        try store.completeScan(id: id, finishedAt: finishedAt, summary: ScanSummary(totalBytes: totalBytes, fileCount: 1, dirCount: Int64(stats.count), volumeFreeBytes: 100, volumeTotalBytes: 200, skippedCount: 0))
        return id
    }

    func testLoadsBaselinesPerWindowAndBuildsRows() throws {
        let rootID = try store.rootID(for: "/r")
        let oldStats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 100, fileCount: 1, newestMtime: 1)]
        let newStats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 160, fileCount: 1, newestMtime: 1)]
        let monthAgo = try complete(rootID: rootID, finishedAt: t0 - 31 * day, stats: oldStats, totalBytes: 100)
        let twoDaysAgo = try complete(rootID: rootID, finishedAt: t0 - 2 * day, stats: [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 130, fileCount: 1, newestMtime: 1)], totalBytes: 130)
        let current = try complete(rootID: rootID, finishedAt: t0, stats: newStats, totalBytes: 160)

        let reports = try ReportLoader.loadRootReports(store: store)

        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.rootPath, "/r")
        XCTAssertEqual(r.current?.id, current)
        XCTAssertEqual(r.latest?.id, current)
        XCTAssertEqual(r.baselines[.day]?.id, twoDaysAgo)
        XCTAssertEqual(r.baselines[.week]?.id, monthAgo, "week window falls back to the most recent scan at or before 7 days ago")
        XCTAssertEqual(r.baselines[.month]?.id, monthAgo)
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].deltas[.day], .changed(30))
        XCTAssertEqual(r.rows[0].deltas[.week], .changed(60))
        XCTAssertEqual(r.rows[0].deltas[.month], .changed(60))
    }

    func testRootWithoutCompletedScanHasNoRowsButKeepsLatest() throws {
        let rootID = try store.rootID(for: "/r")
        let running = try store.beginScan(rootID: rootID, startedAt: t0)
        let reports = try ReportLoader.loadRootReports(store: store)
        XCTAssertNil(reports[0].current)
        XCTAssertEqual(reports[0].latest?.id, running)
        XCTAssertTrue(reports[0].rows.isEmpty)
        XCTAssertTrue(reports[0].baselines.isEmpty)
    }

    func testNoRootsGivesEmptyList() throws {
        XCTAssertTrue(try ReportLoader.loadRootReports(store: store).isEmpty)
    }
}
