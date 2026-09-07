import XCTest
import DiskReportCore
@testable import DiskReportUI

final class FormattingTests: XCTestCase {
    func testByteFormatterBase1000() {
        XCTAssertEqual(ByteFormatter.string(0), "0 B")
        XCTAssertEqual(ByteFormatter.string(999), "999 B")
        XCTAssertEqual(ByteFormatter.string(1000), "1.0 KB")
        XCTAssertEqual(ByteFormatter.string(12_345_678), "12.3 MB")
        XCTAssertEqual(ByteFormatter.string(345_000_000), "345 MB")
        XCTAssertEqual(ByteFormatter.string(1_234_567_890), "1.2 GB")
        XCTAssertEqual(ByteFormatter.string(95_000_000_000), "95.0 GB")
        XCTAssertEqual(ByteFormatter.string(1_500_000_000_000), "1.5 TB")
        XCTAssertEqual(ByteFormatter.string(-1_234_567_890), "-1.2 GB")
    }

    func testDeltaFormatter() {
        XCTAssertEqual(DeltaFormatter.string(.noData), "—")
        XCTAssertEqual(DeltaFormatter.string(.changed(0)), "0 B")
        XCTAssertEqual(DeltaFormatter.string(.changed(340_000_000)), "+340 MB")
        XCTAssertEqual(DeltaFormatter.string(.changed(-12_000_000)), "-12.0 MB")
        XCTAssertEqual(DeltaFormatter.string(.new(1_200_000_000)), "+1.2 GB (new)")
    }

    func testRelativeDates() {
        let now: Int64 = 1_800_000_000
        let day: Int64 = 86_400
        XCTAssertEqual(DateFormatting.relative(mtime: now, now: now), "today")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 3600, now: now), "today")
        XCTAssertEqual(DateFormatting.relative(mtime: now - day, now: now), "yesterday")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 5 * day, now: now), "5 days ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 20 * day, now: now), "2 weeks ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 100 * day, now: now), "3 months ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now - 800 * day, now: now), "2 years ago")
        XCTAssertEqual(DateFormatting.relative(mtime: now + day, now: now), "today")
    }

    func testAbsoluteDateIsISODay() {
        let t = Int64(ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!.timeIntervalSince1970)
        XCTAssertEqual(DateFormatting.absolute(t, timeZone: TimeZone(identifier: "UTC")!), "2026-09-07")
    }
}
