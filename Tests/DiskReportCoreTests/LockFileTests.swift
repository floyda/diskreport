import XCTest
@testable import DiskReportCore

final class LockFileTests: XCTestCase {
    func testSecondHolderIsRefusedUntilFirstReleases() throws {
        let tmp = makeTempDir()
        let url = URL(fileURLWithPath: tmp.path("scan.lock"))
        var first: LockFile? = try LockFile(url: url)
        XCTAssertThrowsError(try LockFile(url: url)) { error in
            XCTAssertEqual(error as? LockFile.Error, .alreadyHeld)
        }
        first = nil
        XCTAssertNoThrow(try LockFile(url: url))
        _ = first
    }

    func testUnopenablePathThrows() {
        XCTAssertThrowsError(try LockFile(url: URL(fileURLWithPath: "/nonexistent-dir/x.lock"))) { error in
            if case .cannotOpen = error as? LockFile.Error {} else { XCTFail("expected cannotOpen, got \(error)") }
        }
    }
}
