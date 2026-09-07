import Darwin
import DiskReportCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("diskreport-scan: \(message)\n".utf8))
    exit(code)
}

let args: Arguments
do {
    args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("diskreport-scan: \(error)\n\(Arguments.usage)\n".utf8))
    exit(1)
}

if let target = args.selfTestWrite {
    exit(runSelfTestWrite(path: target))
}

guard getuid() != 0 else { fail("refusing to run as root", code: 3) }

// Be polite to the interactive user.
setpriority(PRIO_PROCESS, 0, 10)
setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)

let standard = DataPaths.standard()
let paths = DataPaths(
    dataDir: args.dataDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standard.dataDir,
    logDir: args.logDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standard.logDir
)
do { try paths.ensureDirectoriesExist() } catch { fail("cannot create data/log directories: \(error)", code: 1) }

let logger: Logger
do { logger = try Logger(directory: paths.logDir) } catch { fail("cannot open log: \(error)", code: 1) }

let lock: LockFile
do {
    lock = try LockFile(url: paths.lockURL)
} catch LockFile.Error.alreadyHeld {
    fail("another scan is running (lock held: \(paths.lockURL.path))", code: 2)
} catch {
    fail("cannot open lock file: \(error)", code: 1)
}

let configURL = args.configPath.map { URL(fileURLWithPath: $0) } ?? paths.configURL
let config: Config
let roots: [String]
do {
    config = try Config.load(from: configURL)
    roots = try config.resolvedRoots()
} catch {
    logger.log("config error: \(error)")
    fail("\(error)", code: 1)
}

let store: Store
do { store = try Store(url: paths.databaseURL) } catch { fail("cannot open database: \(error)", code: 1) }

func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

do {
    let stale = try store.failStaleRunningScans(now: now())
    if stale > 0 { logger.log("marked \(stale) interrupted scan(s) as failed") }
} catch {
    logger.log("warning: could not mark stale scans: \(error)")
}

var anyFailed = false
for root in roots {
    let started = now()
    let startDate = Date()
    var scanID: Int64 = -1
    do {
        let rootID = try store.rootID(for: root)
        scanID = try store.beginScan(rootID: rootID, startedAt: started)
        logger.log("scan \(scanID) start root=\(root)")

        let result = try Walker().walk(root: root)
        for s in result.skipped { logger.log("skipped \(s.path): \(s.reason)") }
        let volume = try VolumeInfo.query(path: root)
        try store.insertDirStats(scanID: scanID, result.stats)
        let summary = ScanSummary(totalBytes: result.totalBytes, fileCount: result.fileCount,
                                  dirCount: Int64(result.stats.count), volumeFreeBytes: volume.freeBytes,
                                  volumeTotalBytes: volume.totalBytes, skippedCount: Int64(result.skipped.count))
        try store.completeScan(id: scanID, finishedAt: now(), summary: summary)

        let duration = Int(Date().timeIntervalSince(startDate))
        let line = "root=\(root) status=completed total=\(summary.totalBytes) files=\(summary.fileCount) dirs=\(summary.dirCount) skipped=\(summary.skippedCount) duration=\(duration)s"
        logger.log(line)
        print("diskreport-scan: \(line)")

        let toDelete = RetentionPolicy.scansToDelete(try store.scans(rootID: rootID), now: now(), retention: config.retention)
        if !toDelete.isEmpty {
            try store.deleteScans(ids: toDelete)
            logger.log("pruned \(toDelete.count) old scan(s) for root=\(root)")
        }
    } catch {
        anyFailed = true
        let message = "\(error)"
        logger.log("scan \(scanID) FAILED root=\(root): \(message)")
        if scanID >= 0 { try? store.failScan(id: scanID, finishedAt: now(), error: message) }
        print("diskreport-scan: root=\(root) status=failed error=\(message)")
    }
}

print("diskreport-scan: done status=\(anyFailed ? "failed" : "ok")")
withExtendedLifetime(lock) {}
exit(anyFailed ? 4 : 0)
