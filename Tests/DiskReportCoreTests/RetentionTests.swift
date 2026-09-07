import XCTest
@testable import DiskReportCore

final class RetentionTests: XCTestCase {
    private func ts(_ iso: String) -> Int64 {
        let f = ISO8601DateFormatter()
        return Int64(f.date(from: iso)!.timeIntervalSince1970)
    }
    // Monday 2026-09-07 07:00 UTC
    private lazy var now = ts("2026-09-07T07:00:00Z")
    private var nextID: Int64 = 1

    private func scan(_ iso: String, status: ScanStatus = .completed) -> ScanRecord {
        defer { nextID += 1 }
        let t = ts(iso)
        return ScanRecord(id: nextID, rootID: 1, startedAt: t - 60, finishedAt: status == .running ? nil : t, status: status)
    }

    func testRecentScansAllKept() {
        let scans = [scan("2026-09-07T07:00:00Z"), scan("2026-09-06T07:00:00Z"), scan("2026-07-24T07:00:00Z")]
        XCTAssertEqual(RetentionPolicy.scansToDelete(scans, now: now, retention: Retention()), [])
    }

    func testOneScanPerISOWeekBeyondDailyWindow() {
        // Wed 8 Jul and Thu 9 Jul 2026 share ISO week 28; Mon 13 Jul is week 29. All older than 45 days.
        let wed = scan("2026-07-08T07:00:00Z")
        let thu = scan("2026-07-09T07:00:00Z")
        let mon = scan("2026-07-13T07:00:00Z")
        let del = RetentionPolicy.scansToDelete([wed, thu, mon], now: now, retention: Retention())
        XCTAssertEqual(del, [wed.id])
    }

    func testOnePerMonthBeyondWeeklyWindow() {
        // June 2025 is more than 52 weeks before 2026-09-07.
        let early = scan("2025-06-10T07:00:00Z")
        let late = scan("2025-06-20T07:00:00Z")
        let july = scan("2025-07-01T07:00:00Z")
        let del = RetentionPolicy.scansToDelete([early, late, july], now: now, retention: Retention())
        XCTAssertEqual(del, [early.id])
    }

    func testFailedScansKeptOnlyWithinDailyWindow() {
        let recentFailed = scan("2026-09-01T07:00:00Z", status: .failed)
        let oldFailed = scan("2026-06-01T07:00:00Z", status: .failed)
        let del = RetentionPolicy.scansToDelete([recentFailed, oldFailed], now: now, retention: Retention())
        XCTAssertEqual(del, [oldFailed.id])
    }

    func testRunningScansNeverDeleted() {
        let running = scan("2026-01-01T07:00:00Z", status: .running)
        XCTAssertEqual(RetentionPolicy.scansToDelete([running], now: now, retention: Retention()), [])
    }

    func testCustomRetention() {
        let a = scan("2026-09-01T07:00:00Z") // 6 days old
        let b = scan("2026-09-02T07:00:00Z") // 5 days old, same ISO week as a
        let del = RetentionPolicy.scansToDelete([a, b], now: now, retention: Retention(dailyDays: 2, weeklyWeeks: 52))
        XCTAssertEqual(del, [a.id])
    }
}
