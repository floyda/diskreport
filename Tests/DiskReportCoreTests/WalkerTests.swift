import XCTest
@testable import DiskReportCore

final class WalkerTests: XCTestCase {
    private func stat(_ result: WalkResult, _ path: String) -> DirStat? {
        result.stats.first { $0.path == realpathString(path) }
    }

    func testCountsFilesAndBytesRecursivelyPerDirectory() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/one.bin", size: 4096)
        tmp.file("root/a/b/two.bin", size: 4096)
        tmp.file("root/three.bin", size: 4096)
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        let r = try XCTUnwrap(stat(result, root))
        XCTAssertEqual(r.depth, 0)
        XCTAssertNil(r.parentPath)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertGreaterThanOrEqual(r.bytes, 3 * 4096)

        let a = try XCTUnwrap(stat(result, root + "/a"))
        XCTAssertEqual(a.depth, 1)
        XCTAssertEqual(a.parentPath, root)
        XCTAssertEqual(a.fileCount, 2)

        let b = try XCTUnwrap(stat(result, root + "/a/b"))
        XCTAssertEqual(b.depth, 2)
        XCTAssertEqual(b.fileCount, 1)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.totalBytes, r.bytes)
        XCTAssertEqual(result.stats.count, 3)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testEmptyDirectoryHasZeroFilesButOwnAllocation() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root/empty")
        let root = realpathString(tmp.path("root"))
        let result = try Walker().walk(root: root)
        let e = try XCTUnwrap(stat(result, root + "/empty"))
        XCTAssertEqual(e.fileCount, 0)
        XCTAssertGreaterThanOrEqual(e.bytes, 0)
    }

    func testNewestMtimePropagatesToAncestors() throws {
        let tmp = makeTempDir()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        tmp.file("root/a/b/deep.txt", mtime: newer)
        tmp.file("root/c/old.txt", mtime: old)
        tmp.setMtime("root/a/b", old); tmp.setMtime("root/a", old); tmp.setMtime("root/c", old); tmp.setMtime("root", old)
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertEqual(stat(result, root)?.newestMtime, 1_700_000_000)
        XCTAssertEqual(stat(result, root + "/a")?.newestMtime, 1_700_000_000)
        XCTAssertEqual(stat(result, root + "/c")?.newestMtime, 1_000_000)
    }

    func testSymlinksAreNotFollowed() throws {
        let tmp = makeTempDir()
        tmp.file("outside/big.bin", size: 1_000_000)
        tmp.mkdir("root")
        try FileManager.default.createSymbolicLink(atPath: tmp.path("root/link"), withDestinationPath: tmp.path("outside"))
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertNil(stat(result, root + "/link"), "symlink must not appear as a walked directory")
        XCTAssertNil(result.stats.first { $0.path.contains("outside") })
        XCTAssertLessThan(stat(result, root)!.bytes, 100_000)
        XCTAssertEqual(stat(result, root)?.fileCount, 1, "the symlink itself counts as one entry")
    }

    func testHardLinksCountedOnce() throws {
        let tmp = makeTempDir()
        let original = tmp.file("root/a/orig.bin", size: 100_000)
        tmp.mkdir("root/b")
        try FileManager.default.linkItem(atPath: original, toPath: tmp.path("root/b/copy.bin"))
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        let r = try XCTUnwrap(stat(result, root))
        XCTAssertEqual(r.fileCount, 2)
        XCTAssertLessThan(r.bytes, 150_000, "hard-linked file must be counted once")
    }

    func testAllocatedSizeIsUsed() throws {
        let tmp = makeTempDir()
        tmp.file("root/f.bin", size: 1_048_576)
        let root = realpathString(tmp.path("root"))
        let result = try Walker().walk(root: root)
        let r = try XCTUnwrap(stat(result, root))
        XCTAssertGreaterThanOrEqual(r.bytes, 1_048_576)
        XCTAssertEqual(r.bytes % 512, 0, "allocated size is a multiple of 512-byte blocks")
    }

    func testUnreadableDirectoryIsSkippedNotFatal() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        let tmp = makeTempDir()
        tmp.file("root/locked/secret.txt")
        tmp.file("root/ok.txt")
        let locked = tmp.path("root/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let root = realpathString(tmp.path("root"))

        let result = try Walker().walk(root: root)

        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first?.path, realpathString(locked))
        XCTAssertTrue(result.skipped.first!.reason.contains("Permission denied"))
        XCTAssertNotNil(stat(result, realpathString(locked)), "skipped dir still gets a row with what could be seen")
        XCTAssertEqual(stat(result, root)?.fileCount, 1)
    }

    func testRootMustBeDirectory() throws {
        let tmp = makeTempDir()
        let f = tmp.file("notadir.txt")
        XCTAssertThrowsError(try Walker().walk(root: f)) { error in
            XCTAssertEqual(error as? WalkError, .notADirectory(f))
        }
    }

    func testShouldDescendOnlyOnSameDevice() {
        XCTAssertTrue(Walker.shouldDescend(entryDevice: 5, rootDevice: 5))
        XCTAssertFalse(Walker.shouldDescend(entryDevice: 6, rootDevice: 5))
    }

    func testClassifierIsCalledPerDirectory() throws {
        struct MarkNodeModules: DirectoryClassifier {
            func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String? {
                name == "node_modules" ? "node_modules" : nil
            }
        }
        let tmp = makeTempDir()
        tmp.file("root/proj/node_modules/x/index.js")
        tmp.file("root/proj/src/main.js")
        let root = realpathString(tmp.path("root"))

        let result = try Walker(classifier: MarkNodeModules()).walk(root: root)

        XCTAssertEqual(stat(result, root + "/proj/node_modules")?.kind, "node_modules")
        XCTAssertNil(stat(result, root + "/proj/src")?.kind)
    }

    func testVolumeInfo() throws {
        let info = try VolumeInfo.query(path: NSHomeDirectory())
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertGreaterThan(info.freeBytes, 0)
        XCTAssertLessThanOrEqual(info.freeBytes, info.totalBytes)
    }
}
