import XCTest
@testable import DiskReportUI

final class SortKeyTests: XCTestCase {
    func testKeyPathMapping() {
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.name), .name)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.bytes), .bytes)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaDaySort), .deltaDay)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaWeekSort), .deltaWeek)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.deltaMonthSort), .deltaMonth)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.newestMtime), .mtime)
        XCTAssertEqual(SortKey(keyPath: \VisibleRow.fileCount), .files)
        XCTAssertNil(SortKey(keyPath: \VisibleRow.depth))
    }
}
