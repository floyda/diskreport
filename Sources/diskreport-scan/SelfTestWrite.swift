import Darwin
import Foundation

/// Tries to create a file at `path`. Used by tests to prove the sandbox refuses writes into scanned roots.
/// Returns the process exit code: 0 when the write was refused, 10 when it succeeded.
func runSelfTestWrite(path: String) -> Int32 {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd >= 0 {
        close(fd)
        unlink(path)
        FileHandle.standardError.write(Data("self-test-write: SUCCEEDED at \(path) — sandbox is NOT enforcing\n".utf8))
        return 10
    }
    FileHandle.standardError.write(Data("self-test-write: refused (\(String(cString: strerror(errno))))\n".utf8))
    return 0
}
