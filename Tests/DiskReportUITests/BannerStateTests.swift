import XCTest
import DiskReportCore
@testable import DiskReportUI

final class BannerStateTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    private func rec(_ id: Int64, status: ScanStatus, finishedAt: Int64?, error: String? = nil) -> ScanRecord {
        ScanRecord(id: id, rootID: 1, startedAt: 0, finishedAt: finishedAt, status: status, error: error)
    }

    func testNoRoots() {
        XCTAssertEqual(BannerState.message(reports: [], now: now), "No roots configured. Edit config.json and run Scan Now.")
    }

    func testFirstScanPending() {
        let r = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: nil, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "First scan pending. Click Scan Now.")
    }

    func testRunningFirstScanIsAlsoPending() {
        let r = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: rec(1, status: .running, finishedAt: nil), baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "First scan pending. Click Scan Now.")
    }

    func testFailedLatestScan() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: rec(2, status: .failed, finishedAt: now, error: "boom"), baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "Last scan of /w failed: boom")
    }

    func testStaleScan() {
        let cur = rec(1, status: .completed, finishedAt: now - 3 * 86_400)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: cur, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [r], now: now), "Last completed scan of /w is older than 48 hours.")
    }

    func testHealthyReportHasNoBanner() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: cur, baselines: [:], rows: [])
        XCTAssertNil(BannerState.message(reports: [r], now: now))
    }

    func testRunningScanOverHealthyReportHasNoBanner() {
        let cur = rec(1, status: .completed, finishedAt: now - 3600)
        let r = RootReport(rootID: 1, rootPath: "/w", current: cur, latest: rec(2, status: .running, finishedAt: nil), baselines: [:], rows: [])
        XCTAssertNil(BannerState.message(reports: [r], now: now))
    }

    func testFailedRootWinsOverStaleEarlierRoot() {
        let staleCur = rec(1, status: .completed, finishedAt: now - 3 * 86_400)
        let staleRoot = RootReport(rootID: 1, rootPath: "/stale", current: staleCur, latest: staleCur, baselines: [:], rows: [])
        let failedCur = rec(2, status: .completed, finishedAt: now - 3600)
        let failedRoot = RootReport(rootID: 2, rootPath: "/failed", current: failedCur, latest: rec(3, status: .failed, finishedAt: now, error: "boom"), baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [staleRoot, failedRoot], now: now), "Last scan of /failed failed: boom")
    }

    func testPendingRootWinsOverStaleEarlierRoot() {
        let staleCur = rec(1, status: .completed, finishedAt: now - 3 * 86_400)
        let staleRoot = RootReport(rootID: 1, rootPath: "/stale", current: staleCur, latest: staleCur, baselines: [:], rows: [])
        let pendingRoot = RootReport(rootID: 2, rootPath: "/pending", current: nil, latest: nil, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [staleRoot, pendingRoot], now: now), "First scan pending. Click Scan Now.")
    }

    func testStaleBoundary() {
        let staleAfter: Int64 = 172_800
        let exactlyAtBoundary = rec(1, status: .completed, finishedAt: now - staleAfter)
        let atBoundaryRoot = RootReport(rootID: 1, rootPath: "/w", current: exactlyAtBoundary, latest: exactlyAtBoundary, baselines: [:], rows: [])
        XCTAssertNil(BannerState.message(reports: [atBoundaryRoot], now: now, staleAfter: staleAfter))

        let oneSecondOlder = rec(1, status: .completed, finishedAt: now - staleAfter - 1)
        let overBoundaryRoot = RootReport(rootID: 1, rootPath: "/w", current: oneSecondOlder, latest: oneSecondOlder, baselines: [:], rows: [])
        XCTAssertEqual(BannerState.message(reports: [overBoundaryRoot], now: now, staleAfter: staleAfter), "Last completed scan of /w is older than 48 hours.")
    }
}
