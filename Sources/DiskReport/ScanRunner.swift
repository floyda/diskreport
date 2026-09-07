import DiskReportCore
import Foundation

/// Runs the installed scanner binary under the same sandbox profile launchd uses. Never scans in-process.
final class ScanRunner {
    enum RunError: LocalizedError {
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

    func run(completion: @escaping (Result<Void, RunError>) -> Void) {
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
        process.standardOutput = Pipe()
        process.terminationHandler = { p in
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 { completion(.success(())) } else { completion(.failure(.exited(p.terminationStatus, text))) }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(.exited(-1, error.localizedDescription)))
        }
    }
}
