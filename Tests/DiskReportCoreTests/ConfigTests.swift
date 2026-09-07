import XCTest
@testable import DiskReportCore

final class ConfigTests: XCTestCase {
    func testParseDefaultsRetention() throws {
        let cfg = try Config.parse(Data(#"{"roots":["~/Workspace"]}"#.utf8))
        XCTAssertEqual(cfg.roots, ["~/Workspace"])
        XCTAssertEqual(cfg.retention, Retention(dailyDays: 45, weeklyWeeks: 52))
    }

    func testParseExplicitRetention() throws {
        let cfg = try Config.parse(Data(#"{"roots":["/a"],"retention":{"dailyDays":10,"weeklyWeeks":4}}"#.utf8))
        XCTAssertEqual(cfg.retention, Retention(dailyDays: 10, weeklyWeeks: 4))
    }

    func testParseDefaultsMinRecordedBytes() throws {
        let cfg = try Config.parse(Data(#"{"roots":["/a"]}"#.utf8))
        XCTAssertEqual(cfg.minRecordedBytes, 1_000_000)
    }

    func testParseExplicitMinRecordedBytes() throws {
        let cfg = try Config.parse(Data(#"{"roots":["/a"],"minRecordedBytes":0}"#.utf8))
        XCTAssertEqual(cfg.minRecordedBytes, 0)
        let big = try Config.parse(Data(#"{"roots":["/a"],"minRecordedBytes":10485760}"#.utf8))
        XCTAssertEqual(big.minRecordedBytes, 10_485_760)
    }

    func testNegativeMinRecordedBytesClampsToZero() throws {
        let cfg = try Config.parse(Data(#"{"roots":["/a"],"minRecordedBytes":-5}"#.utf8))
        XCTAssertEqual(cfg.minRecordedBytes, 0)
    }

    func testResolvedRootsExpandsTildeAndStripsTrailingSlash() throws {
        let cfg = Config(roots: ["~/Some/Dir/"], retention: Retention())
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = try cfg.resolvedRoots(isDirectory: { _ in true })
        XCTAssertEqual(roots, ["\(home)/Some/Dir"])
    }

    func testResolvedRootsRejectsEmpty() {
        let cfg = Config(roots: [], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in true })) { error in
            XCTAssertEqual(error as? ConfigError, .noRoots)
        }
    }

    func testResolvedRootsRejectsMissingDirectory() {
        let cfg = Config(roots: ["/definitely/missing"], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in false })) { error in
            XCTAssertEqual(error as? ConfigError, .rootNotDirectory("/definitely/missing"))
        }
    }

    func testResolvedRootsRejectsNestedRoots() {
        let cfg = Config(roots: ["/Users/x/Workspace/inner", "/Users/x/Workspace"], retention: Retention())
        XCTAssertThrowsError(try cfg.resolvedRoots(isDirectory: { _ in true })) { error in
            XCTAssertEqual(error as? ConfigError, .nestedRoots(outer: "/Users/x/Workspace", inner: "/Users/x/Workspace/inner"))
        }
    }

    func testResolvedRootsAllowsSiblingWithSharedPrefix() throws {
        let cfg = Config(roots: ["/Users/x/Work", "/Users/x/Workspace"], retention: Retention())
        XCTAssertEqual(try cfg.resolvedRoots(isDirectory: { _ in true }), ["/Users/x/Work", "/Users/x/Workspace"])
    }

    func testLoadFromFile() throws {
        let tmp = makeTempDir()
        let p = tmp.file("config.json", size: 0)
        try Data(#"{"roots":["/tmp"]}"#.utf8).write(to: URL(fileURLWithPath: p))
        let cfg = try Config.load(from: URL(fileURLWithPath: p))
        XCTAssertEqual(cfg.roots, ["/tmp"])
    }

    func testLoadMissingFileThrowsUnreadable() {
        XCTAssertThrowsError(try Config.load(from: URL(fileURLWithPath: "/nope/config.json"))) { error in
            XCTAssertEqual(error as? ConfigError, .unreadable("/nope/config.json"))
        }
    }

    func testDataPathsDerivedURLs() {
        let p = DataPaths(dataDir: URL(fileURLWithPath: "/d"), logDir: URL(fileURLWithPath: "/l"))
        XCTAssertEqual(p.databaseURL.path, "/d/diskreport.sqlite")
        XCTAssertEqual(p.configURL.path, "/d/config.json")
        XCTAssertEqual(p.lockURL.path, "/d/scan.lock")
        XCTAssertEqual(p.binDir.path, "/d/bin")
    }

    func testDataPathsStandard() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = DataPaths.standard()
        XCTAssertEqual(p.dataDir.path, "\(home)/Library/Application Support/DiskReport")
        XCTAssertEqual(p.logDir.path, "\(home)/Library/Logs/DiskReport")
    }

    func testEnsureDirectoriesExistCreatesBoth() throws {
        let tmp = makeTempDir()
        let p = DataPaths(dataDir: URL(fileURLWithPath: tmp.path("data")), logDir: URL(fileURLWithPath: tmp.path("logs")))
        try p.ensureDirectoriesExist()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.dataDir.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.logDir.path, isDirectory: &isDir) && isDir.boolValue)
    }
}
