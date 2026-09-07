import XCTest
@testable import DiskReportCore

final class StalenessTests: XCTestCase {
    let now: Int64 = 1_800_000_000
    let day: Int64 = 86_400

    func testBuckets() {
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now, now: now), .week)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 6 * day, now: now), .week)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 7 * day, now: now), .month)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 29 * day, now: now), .month)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 30 * day, now: now), .sixMonths)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 182 * day, now: now), .sixMonths)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now - 183 * day, now: now), .older)
        XCTAssertEqual(StalenessBucket.bucket(newestMtime: now + day, now: now), .week, "future mtimes are treated as fresh")
    }

    func testWindowCutoffsIncludeSlack() {
        XCTAssertEqual(Window.slack, 6 * 3600)
        XCTAssertEqual(Window.day.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 86_400 + 21_600)
        XCTAssertEqual(Window.week.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 7 * 86_400 + 21_600)
        XCTAssertEqual(Window.month.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 30 * 86_400 + 21_600)
        XCTAssertEqual(Window.allCases, [.day, .week, .month])
    }

    /// The case the slack exists for: yesterday's 07:00 scan took 8 minutes, today's took 12, so a strict
    /// cutoff would leave Δ Day with no baseline even though the scans are a day apart.
    func testYesterdaysSlowerScanStillQualifiesAsDayBaseline() {
        let yesterday = now + 8 * 60
        let today = now + day + 12 * 60
        XCTAssertGreaterThanOrEqual(Window.day.baselineCutoff(currentFinishedAt: today), yesterday)
    }

    /// The slack must never be wide enough to pick up a scan from the same scheduled run.
    func testSlackIsNarrowerThanTheGapBetweenScheduledRuns() {
        XCTAssertLessThan(Window.day.baselineCutoff(currentFinishedAt: now), now)
        XCTAssertLessThan(Window.slack, day)
    }
}
