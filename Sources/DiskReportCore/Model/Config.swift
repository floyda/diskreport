import Foundation

public struct Retention: Codable, Equatable, Sendable {
    public var dailyDays: Int
    public var weeklyWeeks: Int

    public init(dailyDays: Int = 45, weeklyWeeks: Int = 52) {
        self.dailyDays = dailyDays
        self.weeklyWeeks = weeklyWeeks
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case noRoots
    case rootNotDirectory(String)
    case nestedRoots(outer: String, inner: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .noRoots: return "config has no roots"
        case .rootNotDirectory(let p): return "root is not a directory: \(p)"
        case .nestedRoots(let outer, let inner): return "root \(inner) is inside root \(outer); keep only the outer root"
        case .unreadable(let p): return "cannot read config: \(p)"
        }
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// Default floor for storing a directory row: 1 MB. Below this a directory is still walked and
    /// still counts toward its ancestors, it just is not worth a database row of its own.
    public static let defaultMinRecordedBytes: Int64 = 1_000_000

    public var roots: [String]
    public var retention: Retention
    /// Directories smaller than this are not written to `dir_stats` (the root row is always written).
    /// Keeps the database proportional to what the report actually shows instead of to the directory count.
    public var minRecordedBytes: Int64

    public init(roots: [String], retention: Retention = Retention(),
                minRecordedBytes: Int64 = Config.defaultMinRecordedBytes) {
        self.roots = roots
        self.retention = retention
        self.minRecordedBytes = minRecordedBytes
    }

    enum CodingKeys: String, CodingKey { case roots, retention, minRecordedBytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decode([String].self, forKey: .roots)
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
        minRecordedBytes = try c.decodeIfPresent(Int64.self, forKey: .minRecordedBytes) ?? Config.defaultMinRecordedBytes
    }

    public static func parse(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public static func load(from url: URL) throws -> Config {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConfigError.unreadable(url.path)
        }
        return try parse(data)
    }

    /// Expands `~`, strips trailing slashes, validates each root is a directory, rejects nested roots.
    public func resolvedRoots(isDirectory: (String) -> Bool = Config.defaultIsDirectory) throws -> [String] {
        guard !roots.isEmpty else { throw ConfigError.noRoots }
        let expanded = roots.map { raw -> String in
            var p = (raw as NSString).expandingTildeInPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        for p in expanded where !isDirectory(p) {
            throw ConfigError.rootNotDirectory(p)
        }
        for outer in expanded {
            for inner in expanded where inner != outer && inner.hasPrefix(outer + "/") {
                throw ConfigError.nestedRoots(outer: outer, inner: inner)
            }
        }
        return expanded
    }

    public static func defaultIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
