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
func realpathString(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
