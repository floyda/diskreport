import Darwin
import XCTest
@testable import DiskReportCore

/// Runs the real scanner binary under the real sandbox profile and proves nothing under the root changed.
final class SandboxTests: XCTestCase {
    private var profileURL: URL { CLI.packageRoot.appendingPathComponent("Resources/scan.sb") }

    private func sandboxedArgs(tmp: TempDir, scannerArgs: [String]) -> [String] {
        ["-D", "DATA_DIR=\(realpathString(tmp.path("data")))", "-D", "LOG_DIR=\(realpathString(tmp.path("logs")))",
         "-f", profileURL.path, CLI.scannerURL.path] + scannerArgs
    }

    struct Entry: Equatable {
        let path: String, size: Int64, mtime: Int64, mtimeNs: Int, ctime: Int64, ctimeNs: Int
        let inode: UInt64, mode: UInt16, nlink: UInt16, atime: Int64?
    }

    /// Full metadata manifest of a tree. Includes atime only when the volume preserves it on directory reads.
    private func manifest(_ root: String, includeAtime: Bool) throws -> [Entry] {
        var entries: [Entry] = []
        let e = FileManager.default.enumerator(atPath: root)!
        var paths = [root]
        while let rel = e.nextObject() as? String { paths.append(root + "/" + rel) }
        for p in paths.sorted() {
            var st = stat()
            XCTAssertEqual(lstat(p, &st), 0, "lstat \(p)")
            entries.append(Entry(path: p, size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec), mtimeNs: st.st_mtimespec.tv_nsec,
                                 ctime: Int64(st.st_ctimespec.tv_sec), ctimeNs: st.st_ctimespec.tv_nsec,
                                 inode: st.st_ino, mode: st.st_mode, nlink: st.st_nlink,
                                 atime: includeAtime ? Int64(st.st_atimespec.tv_sec) : nil))
        }
        return entries
    }

    /// Probes whether listing a directory changes its atime on this volume.
    private func volumePreservesAtime(_ tmp: TempDir) -> Bool {
        let probe = tmp.mkdir("probe")
        tmp.file("probe/f")
        var before = stat(); lstat(probe, &before)
        Thread.sleep(forTimeInterval: 1.1)
        _ = try? FileManager.default.contentsOfDirectory(atPath: probe)
        var after = stat(); lstat(probe, &after)
        return before.st_atimespec.tv_sec == after.st_atimespec.tv_sec
    }

    func testSandboxedScanLeavesRootMetadataUntouched() throws {
        let tmp = makeTempDir()
        tmp.file("root/a/one.bin", size: 8192)
        tmp.file("root/a/b/two.bin", size: 100)
        tmp.file("root/c/three.txt", size: 10)
        tmp.mkdir("root/empty")
        try FileManager.default.createSymbolicLink(atPath: tmp.path("root/link"), withDestinationPath: tmp.path("root/a"))
        let root = realpathString(tmp.path("root"))
        let includeAtime = volumePreservesAtime(tmp)
        let scannerArgs = try CLI.standardArgs(tmp: tmp, roots: [root])
        Thread.sleep(forTimeInterval: 1.1) // so any accidental touch would move a second-resolution timestamp

        let before = try manifest(root, includeAtime: includeAtime)
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), sandboxedArgs(tmp: tmp, scannerArgs: scannerArgs))
        let after = try manifest(root, includeAtime: includeAtime)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(before, after, "scanner changed something under the root")
        let store = try Store(url: URL(fileURLWithPath: tmp.path("data/diskreport.sqlite")))
        XCTAssertNotNil(try store.latestCompletedScan(rootID: try store.rootID(for: root)))
    }

    func testSandboxRefusesWriteIntoRoot() throws {
        let tmp = makeTempDir()
        tmp.mkdir("root"); tmp.mkdir("data"); tmp.mkdir("logs")
        let target = realpathString(tmp.path("root")) + "/evil.txt"
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                            sandboxedArgs(tmp: tmp, scannerArgs: ["--self-test-write", target]))
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("refused"), r.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testSandboxAllowsWriteIntoDataDir() throws {
        let tmp = makeTempDir()
        tmp.mkdir("data"); tmp.mkdir("logs")
        let target = realpathString(tmp.path("data")) + "/probe.txt"
        let r = try CLI.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                            sandboxedArgs(tmp: tmp, scannerArgs: ["--self-test-write", target]))
        XCTAssertEqual(r.status, 10, "write inside DATA_DIR must be allowed; stderr: \(r.stderr)")
    }

    func testSelfTestWriteSucceedsWithoutSandbox() throws {
        // Proves the self-test is meaningful: unsandboxed, the write goes through.
        let tmp = makeTempDir()
        tmp.mkdir("root")
        let target = realpathString(tmp.path("root")) + "/evil.txt"
        let r = try CLI.run(["--self-test-write", target])
        XCTAssertEqual(r.status, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "self-test cleans up after itself")
    }
}
