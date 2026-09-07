import XCTest
@testable import DiskReportCore

final class NotableTests: XCTestCase {
    private func report(path: String, total: Int64, dayTotal: Int64?, free: Int64) -> RootReport {
        let current = ScanRecord(id: 2, rootID: 1, startedAt: 0, finishedAt: 100, status: .completed, totalBytes: total, volumeFreeBytes: free, volumeTotalBytes: 1000)
        var baselines: [Window: ScanRecord] = [:]
        if let dayTotal {
            baselines[.day] = ScanRecord(id: 1, rootID: 1, startedAt: 0, finishedAt: 10, status: .completed, totalBytes: dayTotal, volumeFreeBytes: free + 5, volumeTotalBytes: 1000)
        }
        return RootReport(rootID: 1, rootPath: path, current: current, latest: current, baselines: baselines, rows: [])
    }

    func testSummaryFromReports() {
        let s = ReportSummary.from([report(path: "/a", total: 500, dayTotal: 450, free: 100), report(path: "/b", total: 20, dayTotal: nil, free: 100)])
        XCTAssertEqual(s.volumeFreeBytes, 100)
        XCTAssertEqual(s.volumeTotalBytes, 1000)
        XCTAssertEqual(s.volumeFreeDeltaDay, -5)
        XCTAssertEqual(s.roots, [RootSummary(rootPath: "/a", totalBytes: 500, deltaDay: 50), RootSummary(rootPath: "/b", totalBytes: 20, deltaDay: nil)])
    }

    func testSummaryWithNoCompletedScans() {
        let r = RootReport(rootID: 1, rootPath: "/a", current: nil, latest: nil, baselines: [:], rows: [])
        let s = ReportSummary.from([r])
        XCTAssertNil(s.volumeFreeBytes)
        XCTAssertEqual(s.roots, [RootSummary(rootPath: "/a", totalBytes: 0, deltaDay: nil)])
    }

    func testEvaluatorWithNoRulesIsQuiet() {
        XCTAssertTrue(NotableEvaluator().notices(for: ReportSummary.from([])).isEmpty)
    }

    func testEvaluatorCollectsNoticesFromRules() {
        struct Always: NotableRule {
            func evaluate(_ summary: ReportSummary) -> Notice? { Notice(title: "t", detail: "d") }
        }
        struct Never: NotableRule {
            func evaluate(_ summary: ReportSummary) -> Notice? { nil }
        }
        let notices = NotableEvaluator(rules: [Always(), Never(), Always()]).notices(for: ReportSummary.from([]))
        XCTAssertEqual(notices, [Notice(title: "t", detail: "d"), Notice(title: "t", detail: "d")])
    }
}
