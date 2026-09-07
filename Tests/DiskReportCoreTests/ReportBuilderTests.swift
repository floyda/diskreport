import XCTest
@testable import DiskReportCore

final class ReportBuilderTests: XCTestCase {
    private func d(_ path: String, _ bytes: Int64, parent: String? = "/r", depth: Int = 1) -> DirStat {
        DirStat(path: path, parentPath: parent, depth: depth, bytes: bytes, fileCount: 1, newestMtime: 10)
    }

    func testChangedNewAndNoData() {
        let current = [d("/r", 300, parent: nil, depth: 0), d("/r/a", 200), d("/r/b", 100)]
        let day = [d("/r", 150, parent: nil, depth: 0), d("/r/a", 150)]
        let rows = ReportBuilder.rows(current: current, baselines: [.day: day])
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })

        XCTAssertEqual(byPath["/r/a"]?.deltas[.day], .changed(50))
        XCTAssertEqual(byPath["/r/b"]?.deltas[.day], .new(100))
        XCTAssertEqual(byPath["/r/a"]?.deltas[.week], .noData)
        XCTAssertEqual(byPath["/r/a"]?.deltas[.month], .noData)
        XCTAssertEqual(byPath["/r"]?.deltas[.day], .changed(150))
        XCTAssertFalse(byPath["/r/a"]!.isDeleted)
        XCTAssertEqual(rows.count, 3)
    }

    func testShrinkIsNegativeDelta() {
        let current = [d("/r/a", 50)]
        let rows = ReportBuilder.rows(current: current, baselines: [.week: [d("/r/a", 80)]])
        XCTAssertEqual(rows[0].deltas[.week], .changed(-30))
    }

    func testDeletedRowsComeFromDayBaselineOnlyWhenParentStillExists() {
        let current = [d("/r", 10, parent: nil, depth: 0), d("/r/keep", 10)]
        let day = [d("/r", 10, parent: nil, depth: 0), d("/r/keep", 10), d("/r/gone", 40),
                   d("/r/gone/child", 20, parent: "/r/gone", depth: 2)]
        let week = [d("/r/other", 5)]
        let rows = ReportBuilder.rows(current: current, baselines: [.day: day, .week: week])
        let deleted = rows.filter(\.isDeleted)

        XCTAssertEqual(deleted.map(\.path), ["/r/gone"], "child of a deleted dir is not listed separately; week baseline never yields deleted rows")
        XCTAssertEqual(deleted[0].bytes, 40)
        XCTAssertEqual(deleted[0].deltas[.day], .changed(-40))
        XCTAssertEqual(deleted[0].deltas[.week], .noData)
        XCTAssertEqual(deleted[0].deltas[.month], .noData)
        XCTAssertEqual(deleted[0].parentPath, "/r")
    }

    func testNoBaselinesAtAll() {
        let rows = ReportBuilder.rows(current: [d("/r/a", 1)], baselines: [:])
        XCTAssertEqual(rows[0].deltas, [.day: .noData, .week: .noData, .month: .noData])
        XCTAssertTrue(rows.allSatisfy { !$0.isDeleted })
    }

    func testDeltaBytesAccessor() {
        XCTAssertNil(Delta.noData.bytes)
        XCTAssertEqual(Delta.new(5).bytes, 5)
        XCTAssertEqual(Delta.changed(-5).bytes, -5)
    }
}
