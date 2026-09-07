import DiskReportCore

public enum QuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all, grewToday, grewThisWeek, new, deleted, staleMonth, staleSixMonths

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .grewToday: return "Grew today"
        case .grewThisWeek: return "Grew this week"
        case .new: return "New"
        case .deleted: return "Deleted"
        case .staleMonth: return "Stale > 1 month"
        case .staleSixMonths: return "Stale > 6 months"
        }
    }

    public func matches(_ row: ReportRow, now: Int64) -> Bool {
        switch self {
        case .all:
            return true
        case .grewToday:
            return !row.isDeleted && (row.deltas[.day]?.bytes ?? 0) > 0
        case .grewThisWeek:
            return !row.isDeleted && (row.deltas[.week]?.bytes ?? 0) > 0
        case .new:
            if case .new = row.deltas[.day] ?? .noData { return true }
            return false
        case .deleted:
            return row.isDeleted
        case .staleMonth:
            let b = StalenessBucket.bucket(newestMtime: row.newestMtime, now: now)
            return !row.isDeleted && (b == .sixMonths || b == .older)
        case .staleSixMonths:
            return !row.isDeleted && StalenessBucket.bucket(newestMtime: row.newestMtime, now: now) == .older
        }
    }
}
