/// Comparison windows. Raw value is the number of days.
public enum Window: Int, CaseIterable, Hashable, Sendable {
    case day = 1
    case week = 7
    case month = 30

    /// Tolerance added to every baseline cutoff, so a scan that ran longer than the previous one still
    /// finds it.
    ///
    /// Scans start at a fixed 07:00 but take a variable amount of time. A strict
    /// `finished_at <= current.finished_at - 86400` means yesterday's scan only qualifies as today's day
    /// baseline if it finished at least as fast as today's — a scan a few minutes slower than the previous
    /// one would silently report "no data" for Δ Day. Six hours absorbs that variance while staying far
    /// short of the 24 hours between scheduled runs, so it can never pull in a scan from the same day.
    public static let slack: Int64 = 6 * 3600

    public var seconds: Int64 { Int64(rawValue) * 86_400 }

    /// Latest allowed finished_at for a baseline scan of this window, including `slack`.
    public func baselineCutoff(currentFinishedAt: Int64) -> Int64 {
        currentFinishedAt - seconds + Window.slack
    }
}
