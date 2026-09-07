import Darwin
import Foundation
import XCTest

/// An isolated temp directory. Create with `makeTempDir()` (below) so XCTest removes it in teardown;
/// removal is deliberately not tied to deinit, because a local can be released before a subprocess finishes.
final class TempDir {
    let url: URL
    init(_ name: String = "diskreport-test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func mkdir(_ relative: String) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Writes `size` bytes of non-zero data so allocated size is real.
    @discardableResult
    func file(_ relative: String, size: Int = 16, mtime: Date? = nil) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: size)
        FileManager.default.createFile(atPath: p, contents: data)
        if let mtime { try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: p) }
        return p
    }

    func setMtime(_ relative: String, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

extension XCTestCase {
    /// Temp directory removed in this test's teardown, even if the test fails.
    func makeTempDir() -> TempDir {
        let tmp = TempDir()
        addTeardownBlock { tmp.remove() }
        return tmp
    }
}

/// Resolves /var → /private/var etc. so comparisons against walker output are stable.
///
/// Foundation's `resolvingSymlinksInPath()` deliberately leaves /tmp, /var, and /etc
/// unresolved, so it does not fully canonicalize paths under the test temp directory
/// (which lives under /var/folders, itself a symlink to /private/var/folders). That
/// matters for SandboxTests: sandbox-exec's `(subpath (param ...))` check matches
/// against the fully-resolved path, so DATA_DIR/LOG_DIR params (and any path compared
/// against them) must be canonical. Go straight to libc realpath(3) instead.
func realpathString(_ path: String) -> String {
    var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.realpath(path, &buf) != nil else {
        fatalError("realpath(\(path)) failed: \(String(cString: strerror(errno)))")
    }
    return String(cString: buf)
}
