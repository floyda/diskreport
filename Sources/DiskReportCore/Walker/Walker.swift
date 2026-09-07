import Darwin
import Foundation

public struct SkippedEntry: Equatable, Sendable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct WalkResult: Sendable {
    public var stats: [DirStat]
    public var skipped: [SkippedEntry]
    public var totalBytes: Int64
    public var fileCount: Int64
}

public enum WalkError: Error, Equatable {
    case notADirectory(String)
}

/// Read-only, depth-first directory walk using POSIX APIs.
/// Never follows symlinks, never crosses devices, counts hard links once, uses allocated size.
public struct Walker {
    private let classifier: DirectoryClassifier
    private let descendPolicy: (_ entryDevice: dev_t, _ rootDevice: dev_t, _ path: String) -> Bool

    public init(classifier: DirectoryClassifier = NoClassifier()) {
        self.classifier = classifier
        self.descendPolicy = { entry, root, _ in Walker.shouldDescend(entryDevice: entry, rootDevice: root) }
    }

    init(classifier: DirectoryClassifier = NoClassifier(),
         descendPolicy: @escaping (_ entryDevice: dev_t, _ rootDevice: dev_t, _ path: String) -> Bool) {
        self.classifier = classifier
        self.descendPolicy = descendPolicy
    }

    public static func shouldDescend(entryDevice: dev_t, rootDevice: dev_t) -> Bool {
        entryDevice == rootDevice
    }

    public func walk(root: String) throws -> WalkResult {
        var st = stat()
        guard lstat(root, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw WalkError.notADirectory(root)
        }
        var ctx = Context(rootDevice: st.st_dev)
        let acc = walkDirectory(path: root, parentPath: nil, depth: 0, dirStat: st, ctx: &ctx)
        return WalkResult(stats: ctx.stats, skipped: ctx.skipped, totalBytes: acc.bytes, fileCount: acc.fileCount)
    }

    // MARK: - Internals

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct Context {
        let rootDevice: dev_t
        var seenInodes = Set<InodeKey>()
        var stats: [DirStat] = []
        var skipped: [SkippedEntry] = []
    }

    private struct Accum {
        var bytes: Int64
        var fileCount: Int64
        var newest: Int64
    }

    private static func allocated(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }
    private static func mtime(_ st: stat) -> Int64 { Int64(st.st_mtimespec.tv_sec) }

    private func walkDirectory(path: String, parentPath: String?, depth: Int, dirStat st: stat, ctx: inout Context) -> Accum {
        var acc = Accum(bytes: Self.allocated(st), fileCount: 0, newest: Self.mtime(st))
        var childNames: [String] = []
        var subdirs: [(path: String, st: stat)] = []

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            ctx.skipped.append(SkippedEntry(path: path, reason: String(cString: strerror(errno))))
        } else if let dir = fdopendir(fd) {
            defer { closedir(dir) } // also closes fd
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                childNames.append(name)

                var est = stat()
                guard fstatat(fd, name, &est, AT_SYMLINK_NOFOLLOW) == 0 else {
                    ctx.skipped.append(SkippedEntry(path: path + "/" + name, reason: String(cString: strerror(errno))))
                    continue
                }
                acc.newest = max(acc.newest, Self.mtime(est))
                let childPath = path + "/" + name

                if (est.st_mode & S_IFMT) == S_IFDIR {
                    if descendPolicy(est.st_dev, ctx.rootDevice, childPath) {
                        subdirs.append((childPath, est))
                    } else {
                        // Mount point itself; record it but do not descend into it.
                        // (acc.newest already picked up est's mtime above.)
                        let mountBytes = Self.allocated(est)
                        let mountKind = classifier.classify(path: childPath, name: name, entries: DirectoryEntrySummary(childNames: []))
                        ctx.stats.append(DirStat(path: childPath, parentPath: path, depth: depth + 1,
                                                 bytes: mountBytes, fileCount: 0, newestMtime: Self.mtime(est), kind: mountKind))
                        acc.bytes += mountBytes
                    }
                } else {
                    acc.fileCount += 1
                    if est.st_nlink > 1 {
                        let key = InodeKey(dev: est.st_dev, ino: est.st_ino)
                        if !ctx.seenInodes.insert(key).inserted { continue }
                    }
                    acc.bytes += Self.allocated(est)
                }
            }
        } else {
            ctx.skipped.append(SkippedEntry(path: path, reason: String(cString: strerror(errno))))
            close(fd)
        }

        for sub in subdirs {
            let s = walkDirectory(path: sub.path, parentPath: path, depth: depth + 1, dirStat: sub.st, ctx: &ctx)
            acc.bytes += s.bytes
            acc.fileCount += s.fileCount
            acc.newest = max(acc.newest, s.newest)
        }

        let name = (path as NSString).lastPathComponent
        let kind = classifier.classify(path: path, name: name, entries: DirectoryEntrySummary(childNames: childNames))
        ctx.stats.append(DirStat(path: path, parentPath: parentPath, depth: depth,
                                 bytes: acc.bytes, fileCount: acc.fileCount, newestMtime: acc.newest, kind: kind))
        return acc
    }
}
