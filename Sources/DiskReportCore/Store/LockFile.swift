import Darwin
import Foundation

/// Exclusive advisory lock so two scanners never run at once. Released on deinit or process exit.
public final class LockFile {
    public enum Error: Swift.Error, Equatable {
        case alreadyHeld
        case cannotOpen(String)
    }

    private let fd: Int32

    public init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Error.cannotOpen(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Error.alreadyHeld
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
