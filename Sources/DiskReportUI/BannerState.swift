import DiskReportCore

public enum BannerState {
    public static func message(reports: [RootReport], now: Int64, staleAfter: Int64 = 172_800) -> String? {
        if reports.isEmpty { return "No roots configured. Edit config.json and run Scan Now." }

        // Severity is evaluated across all roots, not per-root: a failed
        // scan on any root outranks a stale (or pending) scan on an earlier
        // one, and a pending scan on any root outranks staleness elsewhere.
        for r in reports {
            if let latest = r.latest, latest.status == .failed {
                return "Last scan of \(r.rootPath) failed: \(latest.error ?? "unknown error")"
            }
        }
        for r in reports {
            guard r.current != nil, r.current?.finishedAt != nil else {
                return "First scan pending. Click Scan Now."
            }
        }
        for r in reports {
            guard let current = r.current, let finished = current.finishedAt else { continue }
            if now - finished > staleAfter {
                return "Last completed scan of \(r.rootPath) is older than 48 hours."
            }
        }
        return nil
    }
}
