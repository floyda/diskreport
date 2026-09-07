import Darwin
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
        // Open (creating if needed) with a raw syscall rather than FileManager.createFile +
        // FileHandle(forWritingTo:): under the scan sandbox profile (Resources/scan.sb),
        // FileManager's higher-level file-creation path fails silently even for paths inside
        // the allowed subpath, while a plain open() succeeds. O_APPEND also makes every write
        // land at end-of-file without a separate seek, so concurrent loggers can't clobber it.
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: fileURL.path,
                NSLocalizedDescriptionKey: "open(\(fileURL.path)) failed: \(String(cString: strerror(errno)))",
            ])
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
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
