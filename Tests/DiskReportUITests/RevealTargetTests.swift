import XCTest
@testable import DiskReportUI

final class RevealTargetTests: XCTestCase {
    func testURLIsTheFolderItselfNotParentOrChild() {
        let url = RevealTarget.url(forFolder: "/Users/x/Workspace/proj")
        XCTAssertEqual(url.path, "/Users/x/Workspace/proj")
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertTrue(url.isFileURL)
        XCTAssertNotEqual(url.path, "/Users/x/Workspace")
    }
}
