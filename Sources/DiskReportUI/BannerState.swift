import DiskReportCore

public enum BannerState {
    public static func message(reports: [RootReport], now: Int64, staleAfter: Int64 = 172_800) -> String? {
        if reports.isEmpty { return "No roots configured. Edit config.json and run Scan Now." }
        for r in reports {
            if let latest = r.latest, latest.status == .failed {
                return "Last scan of \(r.rootPath) failed: \(latest.error ?? "unknown error")"
            }
            guard let current = r.current, let finished = current.finishedAt else {
                return "First scan pending. Click Scan Now."
            }
            if now - finished > staleAfter {
                return "Last completed scan of \(r.rootPath) is older than 48 hours."
            }
        }
        return nil
    }
}
