import XCTest
@testable import DiskReportCore

final class LoggerTests: XCTestCase {
    func testFileNameUsesDate() {
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        XCTAssertEqual(Logger.fileName(for: d), "scan-2026-09-07.log")
    }

    func testWritesTimestampedLinesAndAppends() throws {
        let tmp = makeTempDir()
        let dir = URL(fileURLWithPath: tmp.path("logs"))
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        do {
            let log = try Logger(directory: dir, now: d)
            log.log("hello")
        }
        let log2 = try Logger(directory: dir, now: d)
        log2.log("again")
        let text = try String(contentsOf: dir.appendingPathComponent("scan-2026-09-07.log"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" hello"))
        XCTAssertTrue(lines[1].hasSuffix(" again"))
        XCTAssertTrue(lines[0].hasPrefix("20"), "line starts with an ISO timestamp")
    }

    func testRotationKeepsNewestFiles() throws {
        let tmp = makeTempDir()
        let dir = URL(fileURLWithPath: tmp.path("logs"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for day in 1...16 {
            let name = String(format: "scan-2026-08-%02d.log", day)
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let d = ISO8601DateFormatter().date(from: "2026-09-07T07:00:00Z")!
        _ = try Logger(directory: dir, maxFiles: 14, now: d)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("scan-") }.sorted()
        XCTAssertEqual(remaining.count, 14)
        XCTAssertEqual(remaining.first, "scan-2026-08-04.log")
        XCTAssertEqual(remaining.last, "scan-2026-09-07.log")
    }
}
