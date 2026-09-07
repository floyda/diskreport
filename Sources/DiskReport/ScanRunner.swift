import DiskReportCore
import Foundation

/// Accumulates a child process's stderr. The readability handler runs on an arbitrary queue and the
/// termination handler on another, so the buffer is behind a lock.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Runs the installed scanner binary under the same sandbox profile launchd uses. Never scans in-process.
final class ScanRunner {
    enum RunError: LocalizedError, Sendable {
        case notInstalled(String)
        case exited(Int32, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let p): return "Scanner not installed at \(p). Run `make install`."
            case .exited(let code, let stderr): return "Scanner exited with code \(code). \(stderr)"
            }
        }
    }

    private let paths: DataPaths

    init(paths: DataPaths) { self.paths = paths }

    func run(completion: @escaping @Sendable (Result<Void, RunError>) -> Void) {
        let scanner = paths.binDir.appendingPathComponent("diskreport-scan")
        let profile = paths.binDir.appendingPathComponent("scan.sb")
        for required in [scanner, profile] where !FileManager.default.fileExists(atPath: required.path) {
            completion(.failure(.notInstalled(required.path)))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-D", "DATA_DIR=\(paths.dataDir.path)",
            "-D", "LOG_DIR=\(paths.logDir.path)",
            "-f", profile.path,
            scanner.path,
            "--data-dir", paths.dataDir.path,
            "--log-dir", paths.logDir.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        // Drain stderr as it arrives. Reading only in the termination handler would deadlock a scanner
        // that logs more than the pipe buffer (64 KB): it blocks writing, so it never terminates, so we
        // never read. One skipped-entry line per unreadable directory reaches that easily.
        let collected = StderrBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(chunk)
            }
        }
        process.terminationHandler = { p in
            let handle = stderr.fileHandleForReading
            handle.readabilityHandler = nil
            collected.append(handle.readDataToEndOfFile())
            let text = String(decoding: collected.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 { completion(.success(())) } else { completion(.failure(.exited(p.terminationStatus, text))) }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(.exited(-1, error.localizedDescription)))
        }
    }
}
