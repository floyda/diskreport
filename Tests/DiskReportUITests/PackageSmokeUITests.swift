import XCTest
@testable import DiskReportUI

final class PackageSmokeUITests: XCTestCase {
    func testPackageBuilds() { XCTAssertEqual(DiskReportUIMarker.version, "0.1.0") }
}
