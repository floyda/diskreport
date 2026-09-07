import XCTest
@testable import DiskReportCore

final class StoreQueryTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!
    private var rootID: Int64 = 0
    private let summary = ScanSummary(totalBytes: 1, fileCount: 1, dirCount: 1, volumeFreeBytes: 1, volumeTotalBytes: 2, skippedCount: 0)

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("q.sqlite")))
        rootID = try store.rootID(for: "/r")
    }

    @discardableResult
    private func completed(startedAt: Int64, finishedAt: Int64, stats: [DirStat] = []) throws -> Int64 {
        let id = try store.beginScan(rootID: rootID, startedAt: startedAt)
        try store.insertDirStats(scanID: id, stats)
        try store.completeScan(id: id, finishedAt: finishedAt, summary: summary)
        return id
    }

    func testLatestScanIncludesFailedAndRunning() throws {
        try completed(startedAt: 100, finishedAt: 150)
        let running = try store.beginScan(rootID: rootID, startedAt: 200)
        XCTAssertEqual(try store.latestScan(rootID: rootID)?.id, running)
        try store.failScan(id: running, finishedAt: 210, error: "x")
        XCTAssertEqual(try store.latestScan(rootID: rootID)?.status, .failed)
    }

    func testLatestCompletedIgnoresFailedAndRunning() throws {
        let c = try completed(startedAt: 100, finishedAt: 150)
        let f = try store.beginScan(rootID: rootID, startedAt: 200)
        try store.failScan(id: f, finishedAt: 210, error: "x")
        _ = try store.beginScan(rootID: rootID, startedAt: 300)
        XCTAssertEqual(try store.latestCompletedScan(rootID: rootID)?.id, c)
    }

    func testLatestCompletedIsNilWhenNoneCompleted() throws {
        _ = try store.beginScan(rootID: rootID, startedAt: 300)
        XCTAssertNil(try store.latestCompletedScan(rootID: rootID))
    }

    func testBaselineScanBoundaries() throws {
        let s100 = try completed(startedAt: 90, finishedAt: 100)
        let s200 = try completed(startedAt: 190, finishedAt: 200)
        _ = try completed(startedAt: 290, finishedAt: 300)
        XCTAssertEqual(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 200)?.id, s200, "inclusive boundary")
        XCTAssertEqual(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 199)?.id, s100)
        XCTAssertNil(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 50))
    }

    func testBaselineIgnoresFailedScansAndOtherRoots() throws {
        let f = try store.beginScan(rootID: rootID, startedAt: 90)
        try store.failScan(id: f, finishedAt: 100, error: "x")
        let other = try store.rootID(for: "/other")
        let oid = try store.beginScan(rootID: other, startedAt: 90)
        try store.completeScan(id: oid, finishedAt: 100, summary: summary)
        XCTAssertNil(try store.baselineScan(rootID: rootID, finishedAtOrBefore: 500))
    }

    func testScansNewestFirst() throws {
        let a = try completed(startedAt: 100, finishedAt: 150)
        let b = try completed(startedAt: 200, finishedAt: 250)
        XCTAssertEqual(try store.scans(rootID: rootID).map(\.id), [b, a])
    }

    func testDirStatsRoundTripOrderedByPath() throws {
        let stats = [
            DirStat(path: "/r/b", parentPath: "/r", depth: 1, bytes: 2, fileCount: 1, newestMtime: 5, kind: "k"),
            DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 3, fileCount: 2, newestMtime: 5),
            DirStat(path: "/r/a", parentPath: "/r", depth: 1, bytes: 1, fileCount: 1, newestMtime: 4),
        ]
        let id = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        XCTAssertEqual(try store.dirStats(scanID: id), [stats[1], stats[2], stats[0]])
    }

    func testDeleteScansCascadesToDirStats() throws {
        let stats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 3, fileCount: 2, newestMtime: 5)]
        let a = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        let b = try completed(startedAt: 3, finishedAt: 4, stats: stats)
        try store.deleteScans(ids: [a])
        XCTAssertNil(try store.scan(id: a))
        XCTAssertEqual(try store.dirStatCount(scanID: a), 0)
        XCTAssertEqual(try store.dirStatCount(scanID: b), 1)
    }

    func testTrimDirStatsRemovesSmallRowsAndKeepsRoot() throws {
        let stats = [
            DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 5, fileCount: 3, newestMtime: 5),
            DirStat(path: "/r/big", parentPath: "/r", depth: 1, bytes: 1_000, fileCount: 1, newestMtime: 5),
            DirStat(path: "/r/small", parentPath: "/r", depth: 1, bytes: 999, fileCount: 1, newestMtime: 5),
        ]
        let id = try completed(startedAt: 1, finishedAt: 2, stats: stats)

        XCTAssertEqual(try store.trimDirStats(rootID: rootID, below: 1_000), 1)
        XCTAssertEqual(try store.dirStats(scanID: id).map(\.path), ["/r", "/r/big"],
                       "depth-0 root row survives even though it is below the threshold")
    }

    func testTrimDirStatsAppliesToEveryScanOfTheRootButNoOthers() throws {
        let stats = [
            DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 5, fileCount: 1, newestMtime: 5),
            DirStat(path: "/r/small", parentPath: "/r", depth: 1, bytes: 10, fileCount: 1, newestMtime: 5),
        ]
        let old = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        let recent = try completed(startedAt: 3, finishedAt: 4, stats: stats)

        let otherRoot = try store.rootID(for: "/other")
        let otherScan = try store.beginScan(rootID: otherRoot, startedAt: 5)
        try store.insertDirStats(scanID: otherScan, [DirStat(path: "/other/small", parentPath: "/other", depth: 1, bytes: 10, fileCount: 1, newestMtime: 5)])
        try store.completeScan(id: otherScan, finishedAt: 6, summary: summary)

        XCTAssertEqual(try store.trimDirStats(rootID: rootID, below: 100), 2, "both scans of the root are trimmed")
        XCTAssertEqual(try store.dirStatCount(scanID: old), 1)
        XCTAssertEqual(try store.dirStatCount(scanID: recent), 1)
        XCTAssertEqual(try store.dirStatCount(scanID: otherScan), 1, "another root is untouched")
    }

    func testTrimDirStatsWithZeroThresholdIsNoop() throws {
        let stats = [DirStat(path: "/r/small", parentPath: "/r", depth: 1, bytes: 0, fileCount: 0, newestMtime: 5)]
        let id = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        XCTAssertEqual(try store.trimDirStats(rootID: rootID, below: 0), 0)
        XCTAssertEqual(try store.dirStatCount(scanID: id), 1)
    }

    func testVacuumKeepsData() throws {
        let stats = [DirStat(path: "/r", parentPath: nil, depth: 0, bytes: 3, fileCount: 2, newestMtime: 5)]
        let id = try completed(startedAt: 1, finishedAt: 2, stats: stats)
        try store.vacuum()
        XCTAssertEqual(try store.dirStats(scanID: id), stats)
    }

    func testDeleteScansWithEmptyListIsNoop() throws {
        try completed(startedAt: 1, finishedAt: 2)
        try store.deleteScans(ids: [])
        XCTAssertEqual(try store.scans(rootID: rootID).count, 1)
    }
}
