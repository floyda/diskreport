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

    func testWindowCutoffs() {
        XCTAssertEqual(Window.day.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 86_400)
        XCTAssertEqual(Window.week.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 7 * 86_400)
        XCTAssertEqual(Window.month.baselineCutoff(currentFinishedAt: 1_000_000), 1_000_000 - 30 * 86_400)
        XCTAssertEqual(Window.allCases, [.day, .week, .month])
    }
}
