import DiskReportCore
import Foundation

public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Finder-style base-1000 sizes. One decimal below 100 units, none above.
    ///
    /// The unit and decimal-count decisions are made consistent with the
    /// displayed rounding: we promote to the next unit while the value would
    /// display as ">= 1000" at the current unit (i.e. `value >= 999.95`), so
    /// e.g. 999_950 bytes reads "1.0 MB" rather than "1000 KB".
    public static func string(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        var value = Double(bytes.magnitude)
        var unit = 0
        while value >= 999.95, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(sign)\(Int(value)) \(units[0])" }
        if value < 99.95 {
            let text = String(format: "%.1f", value)
            return "\(sign)\(text) \(units[unit])"
        }
        // No-decimal branch: round to one decimal first (matching what a
        // reader would see), then drop the fractional digit rather than
        // rounding again to the nearest integer, so 999.949 -> "999.9" ->
        // "999" instead of rounding straight to "1000".
        let rounded = String(format: "%.1f", value)
        let text = String(rounded.dropLast(2))
        return "\(sign)\(text) \(units[unit])"
    }
}

public enum DeltaFormatter {
    public static func string(_ delta: Delta) -> String {
        switch delta {
        case .noData: return "—"
        case .new(let b): return "+\(ByteFormatter.string(b)) (new)"
        case .changed(let b):
            if b == 0 { return "0 B" }
            return b > 0 ? "+\(ByteFormatter.string(b))" : ByteFormatter.string(b)
        }
    }
}

public enum DateFormatting {
    public static func relative(mtime: Int64, now: Int64) -> String {
        let days = max(0, (now - mtime) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    public static func absolute(_ t: Int64, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}
