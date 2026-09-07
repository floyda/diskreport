import XCTest
import DiskReportCore
@testable import DiskReportUI

@MainActor
final class ReportViewModelTests: XCTestCase {
    func testDefaultExpansionShowsThreeLevels() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/x"])
        XCTAssertEqual(vm.visibleRows.map(\.depth), [0, 1, 2, 3, 1])
        XCTAssertTrue(vm.visibleRows[2].isExpanded)
        XCTAssertFalse(vm.visibleRows[3].isExpanded)
        XCTAssertTrue(vm.visibleRows[3].hasChildren)
        XCTAssertFalse(vm.visibleRows[4].hasChildren)
    }

    func testToggleExpandsAndCollapses() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.toggle("/w/a/b/c")
        XCTAssertTrue(vm.visibleRows.map(\.id).contains("/w/a/b/c/d"))
        vm.toggle("/w/a")
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/x"])
        XCTAssertFalse(vm.isExpanded("/w/a"))
        vm.toggle("/w/a")
        XCTAssertTrue(vm.visibleRows.map(\.id).contains("/w/a/b/c/d"), "nested expansion state is remembered")
    }

    func testMultipleRootsAreListedInOrder() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/b", rows: [Fx.row("/b")]), Fx.report("/a", rows: [Fx.row("/a")])], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/b", "/a"])
    }

    func testNameOfRootIsFullPathAndChildrenAreLastComponent() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows[0].name, "/w")
        XCTAssertEqual(vm.visibleRows[1].name, "a")
    }

    func testSortByBytesDescendingWithinSiblings() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w", bytes: 100), Fx.row("/w/small", bytes: 1), Fx.row("/w/big", bytes: 90), Fx.row("/w/mid", bytes: 9)])], now: Fx.now)
        vm.setSort(key: .bytes, ascending: false)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "big", "mid", "small"])
        vm.setSort(key: .bytes, ascending: true)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "small", "mid", "big"])
    }

    func testSortByDeltaPutsNoDataLast() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/a", day: .noData), Fx.row("/w/b", day: .changed(5)), Fx.row("/w/c", day: .new(3))])], now: Fx.now)
        vm.setSort(key: .deltaDay, ascending: false)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "b", "c", "a"])
    }

    func testSortByNameIsCaseInsensitive() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/b"), Fx.row("/w/A"), Fx.row("/w/c")])], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "A", "b", "c"])
    }

    func testFilterGrewTodayShowsMatchesAndAutoExpandsAncestors() {
        let vm = ReportViewModel()
        let rows = [
            Fx.row("/w", day: .changed(10)), Fx.row("/w/a", day: .changed(0)), Fx.row("/w/a/b", day: .changed(0)),
            Fx.row("/w/a/b/c", day: .changed(0)), Fx.row("/w/a/b/c/d", day: .changed(10)), Fx.row("/w/x", day: .changed(-3)),
            Fx.row("/w/y", day: .new(2)),
        ]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .grewToday
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/a/b/c/d", "/w/y"],
                       "ancestors of matches shown and expanded even beyond depth 3; shrinking /w/x hidden; new counts as grew")
        vm.filter = .all
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/x", "/w/y"], "user expansion state unchanged by filtering")
    }

    func testFilterStaleBuckets() {
        let vm = ReportViewModel()
        let rows = [
            Fx.row("/w", mtime: Fx.now), Fx.row("/w/fresh", mtime: Fx.now - 2 * Fx.day),
            Fx.row("/w/month", mtime: Fx.now - 40 * Fx.day), Fx.row("/w/ancient", mtime: Fx.now - 400 * Fx.day),
        ]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .staleMonth
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "ancient", "month"])
        vm.filter = .staleSixMonths
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "ancient"])
    }

    func testFilterDeletedAndNew() {
        let vm = ReportViewModel()
        let rows = [Fx.row("/w"), Fx.row("/w/gone", day: .changed(-5), deleted: true), Fx.row("/w/fresh", day: .new(5)), Fx.row("/w/same", day: .changed(0))]
        vm.load(reports: [Fx.report("/w", rows: rows)], now: Fx.now)
        vm.filter = .deleted
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "gone"])
        XCTAssertTrue(vm.visibleRows[1].isDeleted)
        vm.filter = .new
        XCTAssertEqual(vm.visibleRows.map(\.name), ["/w", "fresh"])
    }

    func testSearchMatchesPathSubstringCaseInsensitively() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.searchText = "C/D"
        XCTAssertEqual(vm.visibleRows.map(\.id), ["/w", "/w/a", "/w/a/b", "/w/a/b/c", "/w/a/b/c/d"])
        vm.searchText = ""
        XCTAssertEqual(vm.visibleRows.count, 5)
    }

    func testVisibleRowCarriesDeltasAndSortKeys() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.report("/w", rows: [Fx.row("/w", bytes: 7, files: 3, day: .changed(-2), week: .new(7), month: .noData)])], now: Fx.now)
        let r = vm.visibleRows[0]
        XCTAssertEqual(r.bytes, 7)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertEqual(r.deltaDay, .changed(-2))
        XCTAssertEqual(r.deltaWeek, .new(7))
        XCTAssertEqual(r.deltaMonth, .noData)
        XCTAssertEqual(r.deltaDaySort, -2)
        XCTAssertEqual(r.deltaWeekSort, 7)
        XCTAssertEqual(r.deltaMonthSort, Int64.min)
    }

    func testLoadResetsExpansionState() {
        let vm = ReportViewModel()
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        vm.toggle("/w/a")
        vm.load(reports: [Fx.deepReport()], now: Fx.now)
        XCTAssertEqual(vm.visibleRows.count, 5)
    }
}
