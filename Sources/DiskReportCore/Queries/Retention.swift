import Foundation

public enum RetentionPolicy {
    /// Returns ids to delete. Keeps: all completed scans within `dailyDays`; the newest completed scan per ISO week
    /// within `weeklyWeeks`; the newest completed scan per calendar month beyond that; failed scans within `dailyDays`;
    /// every running scan.
    public static func scansToDelete(_ scans: [ScanRecord], now: Int64, retention: Retention) -> [Int64] {
        let day: Int64 = 86_400
        let dailyCutoff = now - Int64(retention.dailyDays) * day
        let weeklyCutoff = now - Int64(retention.weeklyWeeks) * 7 * day

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        var keep = Set<Int64>()
        var newestPerWeek: [String: ScanRecord] = [:]
        var newestPerMonth: [String: ScanRecord] = [:]

        for s in scans {
            if s.status == .running { keep.insert(s.id); continue }
            guard let finished = s.finishedAt else { keep.insert(s.id); continue }
            if finished >= dailyCutoff { keep.insert(s.id); continue }
            guard s.status == .completed else { continue } // old failed scans are dropped

            let date = Date(timeIntervalSince1970: TimeInterval(finished))
            if finished >= weeklyCutoff {
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                let key = "\(c.yearForWeekOfYear!)-W\(c.weekOfYear!)"
                if let existing = newestPerWeek[key], (existing.finishedAt ?? 0) >= finished { continue }
                newestPerWeek[key] = s
            } else {
                let c = calendar.dateComponents([.year, .month], from: date)
                let key = "\(c.year!)-M\(c.month!)"
                if let existing = newestPerMonth[key], (existing.finishedAt ?? 0) >= finished { continue }
                newestPerMonth[key] = s
            }
        }
        keep.formUnion(newestPerWeek.values.map(\.id))
        keep.formUnion(newestPerMonth.values.map(\.id))
        return scans.map(\.id).filter { !keep.contains($0) }
    }
}
