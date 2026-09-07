import Darwin
import Foundation

public struct VolumeInfo: Equatable, Sendable {
    public var freeBytes: Int64
    public var totalBytes: Int64

    public enum Error: Swift.Error { case statfsFailed(String) }

    public static func query(path: String) throws -> VolumeInfo {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw Error.statfsFailed(String(cString: strerror(errno))) }
        let bsize = Int64(fs.f_bsize)
        return VolumeInfo(freeBytes: Int64(fs.f_bavail) * bsize, totalBytes: Int64(fs.f_blocks) * bsize)
    }
}
