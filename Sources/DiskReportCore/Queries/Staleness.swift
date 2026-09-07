public enum StalenessBucket: String, CaseIterable, Sendable {
    case week, month, sixMonths, older

    public static func bucket(newestMtime: Int64, now: Int64) -> StalenessBucket {
        let age = now - newestMtime
        let day: Int64 = 86_400
        if age < 7 * day { return .week }
        if age < 30 * day { return .month }
        if age < 183 * day { return .sixMonths }
        return .older
    }
}
