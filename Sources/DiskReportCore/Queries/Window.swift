/// Comparison windows. Raw value is the number of days.
public enum Window: Int, CaseIterable, Hashable, Sendable {
    case day = 1
    case week = 7
    case month = 30

    public var seconds: Int64 { Int64(rawValue) * 86_400 }

    /// Latest allowed finished_at for a baseline scan of this window.
    public func baselineCutoff(currentFinishedAt: Int64) -> Int64 {
        currentFinishedAt - seconds
    }
}
