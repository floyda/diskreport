import Foundation

/// Appends timestamped lines to `scan-YYYY-MM-DD.log` and keeps at most `maxFiles` such files.
public final class Logger {
    public let fileURL: URL
    private let handle: FileHandle

    public static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "scan-\(f.string(from: date)).log"
    }

    public init(directory: URL, maxFiles: Int = 14, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(Logger.fileName(for: now))
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        Logger.rotate(directory: directory, maxFiles: maxFiles)
    }

    deinit { try? handle.close() }

    public func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let data = "\(stamp) \(message)\n".data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static func rotate(directory: URL, maxFiles: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let logs = names.filter { $0.hasPrefix("scan-") && $0.hasSuffix(".log") }.sorted()
        guard logs.count > maxFiles else { return }
        for name in logs.prefix(logs.count - maxFiles) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
