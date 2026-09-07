public extension SortKey {
    /// Maps a Table column key path back to a sort key.
    init?(keyPath: PartialKeyPath<VisibleRow>) {
        switch keyPath {
        case \VisibleRow.name: self = .name
        case \VisibleRow.bytes: self = .bytes
        case \VisibleRow.deltaDaySort: self = .deltaDay
        case \VisibleRow.deltaWeekSort: self = .deltaWeek
        case \VisibleRow.deltaMonthSort: self = .deltaMonth
        case \VisibleRow.newestMtime: self = .mtime
        case \VisibleRow.fileCount: self = .files
        default: return nil
        }
    }
}
