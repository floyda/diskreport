import Foundation

/// One directory as observed by a single scan. `bytes`, `fileCount`, `newestMtime` are recursive.
public struct DirStat: Equatable, Sendable {
    public var path: String
    public var parentPath: String?
    public var depth: Int
    public var bytes: Int64
    public var fileCount: Int64
    public var newestMtime: Int64
    public var kind: String?

    public init(path: String, parentPath: String?, depth: Int, bytes: Int64, fileCount: Int64, newestMtime: Int64, kind: String? = nil) {
        self.path = path
        self.parentPath = parentPath
        self.depth = depth
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestMtime = newestMtime
        self.kind = kind
    }
}

public enum ScanStatus: String, Sendable {
    case running, completed, failed
}

public struct ScanSummary: Equatable, Sendable {
    public var totalBytes: Int64
    public var fileCount: Int64
    public var dirCount: Int64
    public var volumeFreeBytes: Int64
    public var volumeTotalBytes: Int64
    public var skippedCount: Int64

    public init(totalBytes: Int64, fileCount: Int64, dirCount: Int64, volumeFreeBytes: Int64, volumeTotalBytes: Int64, skippedCount: Int64) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.skippedCount = skippedCount
    }
}

public struct ScanRecord: Equatable, Sendable {
    public var id: Int64
    public var rootID: Int64
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var status: ScanStatus
    public var totalBytes: Int64?
    public var fileCount: Int64?
    public var dirCount: Int64?
    public var volumeFreeBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var skippedCount: Int64?
    public var error: String?

    public init(id: Int64, rootID: Int64, startedAt: Int64, finishedAt: Int64?, status: ScanStatus,
                totalBytes: Int64? = nil, fileCount: Int64? = nil, dirCount: Int64? = nil,
                volumeFreeBytes: Int64? = nil, volumeTotalBytes: Int64? = nil, skippedCount: Int64? = nil,
                error: String? = nil) {
        self.id = id
        self.rootID = rootID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.volumeFreeBytes = volumeFreeBytes
        self.volumeTotalBytes = volumeTotalBytes
        self.skippedCount = skippedCount
        self.error = error
    }
}
