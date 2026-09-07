import XCTest
@testable import DiskReportCore

final class PackageSmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertEqual(DiskReportCoreMarker.version, "0.1.0") }
}
