import XCTest
import DiskReportCore
@testable import DiskReportUI

final class TreeBuilderTests: XCTestCase {
    func testBuildsOneTreePerRootWithChildrenSortedByName() {
        let r1 = Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/zeta"), Fx.row("/w/alpha"), Fx.row("/w/alpha/inner")])
        let r2 = Fx.report("/other", rows: [Fx.row("/other")])
        let roots = TreeBuilder.build([r1, r2])

        XCTAssertEqual(roots.map(\.id), ["/w", "/other"])
        XCTAssertEqual(roots[0].name, "/w", "root nodes show the full path")
        XCTAssertEqual(roots[0].children.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(roots[0].children[0].children.map(\.id), ["/w/alpha/inner"])
        XCTAssertTrue(roots[0].children[0].children[0].parent === roots[0].children[0])
    }

    func testReportWithoutRowsProducesNoTree() {
        let empty = RootReport(rootID: 1, rootPath: "/w", current: nil, latest: nil, baselines: [:], rows: [])
        XCTAssertTrue(TreeBuilder.build([empty]).isEmpty)
    }

    func testDeletedRowsAttachToParent() {
        let r = Fx.report("/w", rows: [Fx.row("/w"), Fx.row("/w/gone", day: .changed(-5), deleted: true)])
        let roots = TreeBuilder.build([r])
        XCTAssertEqual(roots[0].children.map(\.id), ["/w/gone"])
        XCTAssertTrue(roots[0].children[0].row.isDeleted)
    }
}
