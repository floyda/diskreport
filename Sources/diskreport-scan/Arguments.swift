import Foundation

struct Arguments {
    var configPath: String?
    var dataDir: String?
    var logDir: String?
    var selfTestWrite: String?

    static let usage = """
    usage: diskreport-scan [--config PATH] [--data-dir PATH] [--log-dir PATH] [--self-test-write PATH]
      --config           config.json path (default: <data-dir>/config.json)
      --data-dir         database/lock directory (default: ~/Library/Application Support/DiskReport)
      --log-dir          log directory (default: ~/Library/Logs/DiskReport)
      --self-test-write  attempt to create PATH and exit: 0 if refused (sandbox works), 10 if it succeeded
    """

    enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        var description: String {
            switch self {
            case .unknown(let f): return "unknown argument: \(f)"
            case .missingValue(let f): return "missing value for \(f)"
            }
        }
    }

    static func parse(_ argv: [String]) throws -> Arguments {
        var a = Arguments()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count else { throw ParseError.missingValue(flag) }
            return argv[i]
        }
        while i < argv.count {
            let flag = argv[i]
            switch flag {
            case "--config": a.configPath = try value(flag)
            case "--data-dir": a.dataDir = try value(flag)
            case "--log-dir": a.logDir = try value(flag)
            case "--self-test-write": a.selfTestWrite = try value(flag)
            default: throw ParseError.unknown(flag)
            }
            i += 1
        }
        return a
    }
}
