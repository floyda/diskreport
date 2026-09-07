import Combine
import DiskReportCore
import Foundation

public enum SortKey: Equatable, Sendable {
    case name, bytes, deltaDay, deltaWeek, deltaMonth, mtime, files
}

/// One row of the flattened, filtered, sorted table.
public struct VisibleRow: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let isDeleted: Bool
    public let bytes: Int64
    public let fileCount: Int64
    public let newestMtime: Int64
    public let deltaDay: Delta
    public let deltaWeek: Delta
    public let deltaMonth: Delta
    public let kind: String?

    /// Sort keys: `.noData` sorts below every real value.
    public var deltaDaySort: Int64 { deltaDay.bytes ?? Int64.min }
    public var deltaWeekSort: Int64 { deltaWeek.bytes ?? Int64.min }
    public var deltaMonthSort: Int64 { deltaMonth.bytes ?? Int64.min }

    init(node: DirNode, isExpanded: Bool) {
        let r = node.row
        id = node.id
        name = node.name
        depth = r.depth
        hasChildren = !node.children.isEmpty
        self.isExpanded = isExpanded
        isDeleted = r.isDeleted
        bytes = r.bytes
        fileCount = r.fileCount
        newestMtime = r.newestMtime
        deltaDay = r.deltas[.day] ?? .noData
        deltaWeek = r.deltas[.week] ?? .noData
        deltaMonth = r.deltas[.month] ?? .noData
        kind = r.kind
    }
}

@MainActor
public final class ReportViewModel: ObservableObject {
    /// Rows with depth <= this are visible by default (root is depth 0).
    public static let defaultVisibleDepth = 3

    @Published public private(set) var visibleRows: [VisibleRow] = []
    @Published public var filter: QuickFilter = .all { didSet { rebuild() } }
    @Published public var searchText: String = "" { didSet { rebuild() } }
    @Published public private(set) var sortKey: SortKey = .name
    @Published public private(set) var sortAscending: Bool = true

    public private(set) var roots: [DirNode] = []
    public private(set) var now: Int64 = 0
    private var expanded: Set<String> = []

    public init() {}

    public func load(reports: [RootReport], now: Int64) {
        load(roots: TreeBuilder.build(reports), now: now)
    }

    /// Adopts a tree built elsewhere. Building it costs a pass over every row, so the app builds it on the
    /// same background task as the database read and hands the finished tree over (see `DirNode`'s
    /// `@unchecked Sendable` note).
    public func load(roots: [DirNode], now: Int64) {
        self.roots = roots
        self.now = now
        expanded = []
        for root in roots { expandDefault(root) }
        rebuild()
    }

    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuild()
    }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public func setSort(key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        rebuild()
    }

    // MARK: - Internals

    private func expandDefault(_ node: DirNode) {
        guard node.row.depth < Self.defaultVisibleDepth, !node.children.isEmpty else { return }
        expanded.insert(node.id)
        for c in node.children { expandDefault(c) }
    }

    private var isFiltering: Bool { filter != .all || !searchText.isEmpty }

    private func matches(_ node: DirNode) -> Bool {
        guard filter.matches(node.row, now: now) else { return false }
        return searchText.isEmpty || node.row.path.localizedCaseInsensitiveContains(searchText)
    }

    /// Whether the node or any descendant matches. Memoized per rebuild.
    private func hasMatch(_ node: DirNode, cache: inout [String: Bool]) -> Bool {
        if let cached = cache[node.id] { return cached }
        var result = matches(node)
        if !result {
            for c in node.children where hasMatch(c, cache: &cache) { result = true; break }
        }
        cache[node.id] = result
        return result
    }

    private func comparator() -> (DirNode, DirNode) -> Bool {
        let asc = sortAscending
        func byName(_ a: DirNode, _ b: DirNode) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func numeric(_ key: @escaping (DirNode) -> Int64) -> (DirNode, DirNode) -> Bool {
            return { a, b in
                let ka = key(a), kb = key(b)
                if ka == kb { return byName(a, b) }
                return asc ? ka < kb : ka > kb
            }
        }
        switch sortKey {
        case .name: return { a, b in asc ? byName(a, b) : byName(b, a) }
        case .bytes: return numeric { $0.row.bytes }
        case .files: return numeric { $0.row.fileCount }
        case .mtime: return numeric { $0.row.newestMtime }
        case .deltaDay: return numeric { $0.row.deltas[.day]?.bytes ?? Int64.min }
        case .deltaWeek: return numeric { $0.row.deltas[.week]?.bytes ?? Int64.min }
        case .deltaMonth: return numeric { $0.row.deltas[.month]?.bytes ?? Int64.min }
        }
    }

    private func rebuild() {
        var out: [VisibleRow] = []
        var cache: [String: Bool] = [:]
        let less = comparator()
        let filtering = isFiltering

        func visit(_ node: DirNode) {
            if filtering && !hasMatch(node, cache: &cache) { return }
            let shownChildren = node.children.filter { !filtering || hasMatch($0, cache: &cache) }
            let childHasMatch = filtering && shownChildren.contains { hasMatch($0, cache: &cache) }
            let open = !shownChildren.isEmpty && (expanded.contains(node.id) || childHasMatch)
            out.append(VisibleRow(node: node, isExpanded: open))
            guard open else { return }
            for c in shownChildren.sorted(by: less) { visit(c) }
        }
        for root in roots { visit(root) }
        visibleRows = out
    }
}
