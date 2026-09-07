import Foundation

/// Where DiskReport keeps its own state. Always outside any scanned root.
public struct DataPaths: Sendable {
    public let dataDir: URL
    public let logDir: URL

    public init(dataDir: URL, logDir: URL) {
        self.dataDir = dataDir
        self.logDir = logDir
    }

    public static func standard() -> DataPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return DataPaths(
            dataDir: home.appendingPathComponent("Library/Application Support/DiskReport", isDirectory: true),
            logDir: home.appendingPathComponent("Library/Logs/DiskReport", isDirectory: true)
        )
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("diskreport.sqlite") }
    public var configURL: URL { dataDir.appendingPathComponent("config.json") }
    public var lockURL: URL { dataDir.appendingPathComponent("scan.lock") }
    public var binDir: URL { dataDir.appendingPathComponent("bin", isDirectory: true) }

    public func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
