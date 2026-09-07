import XCTest
@testable import DiskReportCore

final class StoreTests: XCTestCase {
    private var tmp: TempDir!
    private var store: Store!

    override func setUpWithError() throws {
        tmp = makeTempDir()
        store = try Store(url: URL(fileURLWithPath: tmp.path("test.sqlite")))
    }

    override func tearDown() { store = nil; tmp = nil }

    private func sampleStats(root: String = "/r") -> [DirStat] {
        [
            DirStat(path: root, parentPath: nil, depth: 0, bytes: 300, fileCount: 3, newestMtime: 30),
            DirStat(path: root + "/a", parentPath: root, depth: 1, bytes: 200, fileCount: 2, newestMtime: 30, kind: nil),
            DirStat(path: root + "/a/b", parentPath: root + "/a", depth: 2, bytes: 100, fileCount: 1, newestMtime: 20, kind: "build"),
        ]
    }

    private let summary = ScanSummary(totalBytes: 300, fileCount: 3, dirCount: 3, volumeFreeBytes: 1000, volumeTotalBytes: 5000, skippedCount: 0)

    func testRootIDIsStablePerPath() throws {
        let a = try store.rootID(for: "/r")
        let b = try store.rootID(for: "/r")
        let c = try store.rootID(for: "/other")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(try store.roots(), [RootEntry(id: a, path: "/r"), RootEntry(id: c, path: "/other")])
    }

    func testBeginInsertCompleteRoundTrip() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 100)
        XCTAssertEqual(try store.scan(id: scanID)?.status, .running)

        try store.insertDirStats(scanID: scanID, sampleStats())
        try store.completeScan(id: scanID, finishedAt: 160, summary: summary)

        let rec = try XCTUnwrap(try store.scan(id: scanID))
        XCTAssertEqual(rec, ScanRecord(id: scanID, rootID: rootID, startedAt: 100, finishedAt: 160, status: .completed,
                                       totalBytes: 300, fileCount: 3, dirCount: 3, volumeFreeBytes: 1000,
                                       volumeTotalBytes: 5000, skippedCount: 0, error: nil))
        XCTAssertEqual(try store.dirStatCount(scanID: scanID), 3)
    }

    func testFailScanStoresError() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 100)
        try store.failScan(id: scanID, finishedAt: 120, error: "boom")
        let rec = try XCTUnwrap(try store.scan(id: scanID))
        XCTAssertEqual(rec.status, .failed)
        XCTAssertEqual(rec.error, "boom")
        XCTAssertEqual(rec.finishedAt, 120)
    }

    func testFailStaleRunningScansMarksAllRunning() throws {
        let rootID = try store.rootID(for: "/r")
        let s1 = try store.beginScan(rootID: rootID, startedAt: 100)
        let s2 = try store.beginScan(rootID: rootID, startedAt: 200)
        try store.completeScan(id: s2, finishedAt: 260, summary: summary)

        XCTAssertEqual(try store.failStaleRunningScans(now: 500), 1)

        XCTAssertEqual(try store.scan(id: s1)?.status, .failed)
        XCTAssertEqual(try store.scan(id: s1)?.error, "interrupted")
        XCTAssertEqual(try store.scan(id: s1)?.finishedAt, 500)
        XCTAssertEqual(try store.scan(id: s2)?.status, .completed)
        XCTAssertEqual(try store.failStaleRunningScans(now: 600), 0)
    }

    func testInsertManyRowsIsFast() throws {
        let rootID = try store.rootID(for: "/r")
        let scanID = try store.beginScan(rootID: rootID, startedAt: 1)
        let rows = (0..<20_000).map { i in
            DirStat(path: "/r/\(i)", parentPath: "/r", depth: 1, bytes: Int64(i), fileCount: 1, newestMtime: 1)
        }
        let start = Date()
        try store.insertDirStats(scanID: scanID, rows)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        XCTAssertEqual(try store.dirStatCount(scanID: scanID), 20_000)
    }

    func testReopeningKeepsData() throws {
        let url = URL(fileURLWithPath: tmp.path("persist.sqlite"))
        do {
            let s = try Store(url: url)
            let rootID = try s.rootID(for: "/r")
            let id = try s.beginScan(rootID: rootID, startedAt: 1)
            try s.completeScan(id: id, finishedAt: 2, summary: summary)
        }
        let again = try Store(url: url)
        XCTAssertEqual(try again.roots().count, 1)
    }
}
