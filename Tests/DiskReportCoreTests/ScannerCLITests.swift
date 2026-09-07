import XCTest
@testable import DiskReportCore

struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Shared helpers for running the built `diskreport-scan` binary.
enum CLI {
    static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn't find the products directory")
    }

    static var scannerURL: URL { productsDirectory.appendingPathComponent("diskreport-scan") }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @discardableResult
    static func run(executable: URL = scannerURL, _ args: [String]) throws -> CLIResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CLIResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    /// Writes a config pointing at `roots` and returns the standard argument list for an isolated run.
    /// `minRecordedBytes` defaults to 0 so fixture directories of a few KB are still recorded.
    static func standardArgs(tmp: TempDir, roots: [String], minRecordedBytes: Int = 0) throws -> [String] {
        let data = tmp.mkdir("data")
        let logs = tmp.mkdir("logs")
        let cfg = tmp.path("config.json")
        let json = try JSONSerialization.data(withJSONObject: ["roots": roots, "minRecordedBytes": minRecordedBytes])
        try json.write(to: URL(fileURLWithPath: cfg))
        return ["--config", cfg, "--data-dir", data, "--log-dir", logs]
    }
}

final class ScannerCLITests: XCTestCase {
    func testScansFixtureAndRecordsCompletedScan() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/x.bin", size: 4096)
        tmp.file("root/b/y.bin", size: 4096)
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])

        let r = try CLI.run(args)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("root=\(root) status=completed"), r.stdout)
        XCTAssertTrue(r.stdout.contains("files=2"), r.stdout)
        XCTAssertTrue(r.stdout.contains("dirs=3"), r.stdout)
        XCTAssertTrue(r.stdout.contains("walked=3"), r.stdout)
        XCTAssertTrue(r.stdout.contains("done status=ok"), r.stdout)

        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let rootID = try store.rootID(for: root)
        let scan = try XCTUnwrap(try store.latestCompletedScan(rootID: rootID))
        XCTAssertEqual(scan.dirCount, 3)
        XCTAssertEqual(scan.fileCount, 2)
        XCTAssertGreaterThan(scan.volumeFreeBytes ?? 0, 0)
        XCTAssertEqual(try store.dirStatCount(scanID: scan.id), 3)

        let logs = try FileManager.default.contentsOfDirectory(atPath: tmp.path("logs"))
        XCTAssertEqual(logs.filter { $0.hasPrefix("scan-") }.count, 1)
    }

    func testSecondRunAddsSecondScan() throws {
        let tmp = makeTempDir()
        tmp.file("root/x.bin")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])
        XCTAssertEqual(try CLI.run(args).status, 0)
        XCTAssertEqual(try CLI.run(args).status, 0)
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        XCTAssertEqual(try store.scans(rootID: try store.rootID(for: root)).count, 2)
    }

    func testMissingConfigExits1() throws {
        let tmp = makeTempDir()
        let r = try CLI.run(["--config", tmp.path("nope.json"), "--data-dir", tmp.mkdir("d"), "--log-dir", tmp.mkdir("l")])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("cannot read config"), r.stderr)
    }

    func testNestedRootsExits1WithExplanation() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root/inner")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root, root + "/inner"])
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("keep only the outer root"), r.stderr)
    }

    func testMissingRootExits1ButStillScansNothing() throws {
        let tmp = makeTempDir()
        let args = try CLI.standardArgs(tmp: tmp, roots: [tmp.path("does-not-exist")])
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("not a directory"), r.stderr)
    }

    func testLockHeldExits2() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let args = try CLI.standardArgs(tmp: tmp, roots: [realpathString(tmp.path("root"))])
        let held = try LockFile(url: URL(fileURLWithPath: tmp.path("data/scan.lock")))
        let r = try CLI.run(args)
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.stderr.contains("another scan is running"), r.stderr)
        _ = held
    }

    func testUnknownFlagExits1WithUsage() throws {
        let r = try CLI.run(["--bogus"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("usage:"), r.stderr)
    }

    func testRootFailureExits4AndContinuesOtherRoots() throws {
        let tmp = makeTempDir()
        tmp.file("rootA/x.bin")
        let rootA = realpathString(tmp.path("rootA"))

        let target = tmp.mkdir("target")
        let rootBPath = tmp.path("rootB")
        try FileManager.default.createSymbolicLink(atPath: rootBPath, withDestinationPath: target)

        let args = try CLI.standardArgs(tmp: tmp, roots: [rootA, rootBPath])
        let r = try CLI.run(args)

        XCTAssertEqual(r.status, 4, r.stderr)
        XCTAssertTrue(r.stdout.contains("root=\(rootA) status=completed"), r.stdout)
        XCTAssertTrue(r.stdout.contains("root=\(rootBPath) status=failed error="), r.stdout)
        XCTAssertTrue(r.stdout.contains("done status=failed"), r.stdout)

        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let scanA = try XCTUnwrap(try store.latestCompletedScan(rootID: try store.rootID(for: rootA)))
        XCTAssertEqual(scanA.status, .completed)
        let scanB = try XCTUnwrap(try store.latestScan(rootID: try store.rootID(for: rootBPath)))
        XCTAssertEqual(scanB.status, .failed)
    }

    func testMinRecordedBytesFiltersSmallDirectories() throws {
        let tmp = makeTempDir()
        tmp.file("root/big/one.bin", size: 2_000_000)
        tmp.file("root/small/tiny.txt", size: 16)
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root], minRecordedBytes: 1_000_000)

        let r = try CLI.run(args)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains("dirs=2"), r.stdout)
        XCTAssertTrue(r.stdout.contains("walked=3"), r.stdout)

        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let scan = try XCTUnwrap(try store.latestCompletedScan(rootID: try store.rootID(for: root)))
        XCTAssertEqual(scan.dirCount, 2)
        XCTAssertEqual(try store.dirStats(scanID: scan.id).map(\.path), [root, root + "/big"],
                       "the root is always recorded; root/small is walked but too small to store")
    }

    func testRunningScanFromPreviousCrashIsMarkedFailed() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let root = realpathString(tmp.path("root"))
        let args = try CLI.standardArgs(tmp: tmp, roots: [root])
        do {
            let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
            _ = try store.beginScan(rootID: try store.rootID(for: root), startedAt: 1)
        }
        XCTAssertEqual(try CLI.run(args).status, 0)
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        let scans = try store.scans(rootID: try store.rootID(for: root))
        XCTAssertEqual(scans.map(\.status), [.completed, .failed])
        XCTAssertEqual(scans[1].error, "interrupted")
    }
}
