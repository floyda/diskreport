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
    /// Nodes with depth less than this are expanded by default, revealing their children (root is
    /// depth 0). With the default of `1`, each root is expanded so its top-level children are
    /// visible, but nothing deeper is expanded automatically.
    public static let defaultVisibleDepth = 1

    /// Depth `expandAll()` opens the tree to.
    public static let deepVisibleDepth = 3

    @Published public private(set) var visibleRows: [VisibleRow] = []
    @Published public var filter: QuickFilter = .all {
        didSet {
            if isFiltering { recomputeFilteredExpanded() }
            rebuild()
        }
    }
    @Published public var searchText: String = "" {
        didSet {
            if isFiltering { recomputeFilteredExpanded() }
            rebuild()
        }
    }
    @Published public private(set) var sortKey: SortKey = .name
    @Published public private(set) var sortAscending: Bool = true

    public private(set) var roots: [DirNode] = []
    public private(set) var now: Int64 = 0

    /// Expansion state for the unfiltered ("All", no search) view.
    private var expanded: Set<String> = []
    /// Expansion state for the current filtered/search view. Kept separate from `expanded` so
    /// switching a quick filter or search off restores the user's unfiltered expansion unchanged.
    /// Reset (and re-populated with every ancestor of a match) whenever the filter or search text
    /// changes; the user's own toggles from then on are layered on top of that until it changes again.
    private var filteredExpanded: Set<String> = []

    /// The expansion set that `rebuild()`, `isExpanded`, and every mutator currently read/write:
    /// `filteredExpanded` while a quick filter or search is active, `expanded` otherwise.
    private var activeExpanded: Set<String> {
        get { isFiltering ? filteredExpanded : expanded }
        set { if isFiltering { filteredExpanded = newValue } else { expanded = newValue } }
    }

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
        var freshExpanded: Set<String> = []
        for root in roots { expand(root, toDepth: Self.defaultVisibleDepth, into: &freshExpanded) }
        expanded = freshExpanded
        // A filter/search can already be active when the app reloads (the database changed
        // underneath it); recompute the filtered view's auto-expansion against the new tree too.
        if isFiltering { recomputeFilteredExpanded() } else { filteredExpanded = [] }
        rebuild()
    }

    public func toggle(_ id: String) {
        if activeExpanded.contains(id) { activeExpanded.remove(id) } else { activeExpanded.insert(id) }
        rebuild()
    }

    /// Expands a single node, revealing its children if any. No-op (no rebuild) if already expanded.
    public func expand(_ id: String) {
        guard !activeExpanded.contains(id) else { return }
        activeExpanded.insert(id)
        rebuild()
    }

    /// Collapses a single node. No-op (no rebuild) if already collapsed.
    public func collapse(_ id: String) {
        guard activeExpanded.contains(id) else { return }
        activeExpanded.remove(id)
        rebuild()
    }

    /// Expands every id in `ids`, rebuilding once.
    public func expand(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        var set = activeExpanded
        var changed = false
        for id in ids where !set.contains(id) {
            set.insert(id)
            changed = true
        }
        if changed { activeExpanded = set; rebuild() }
    }

    /// Collapses every id in `ids`, rebuilding once.
    public func collapse(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        var set = activeExpanded
        var changed = false
        for id in ids where set.contains(id) {
            set.remove(id)
            changed = true
        }
        if changed { activeExpanded = set; rebuild() }
    }

    public func isExpanded(_ id: String) -> Bool { activeExpanded.contains(id) }

    public func setSort(key: SortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        rebuild()
    }

    /// Collapses the tree back to the default: only each root is expanded, so their top-level
    /// children stay listed. Acts on whichever view (filtered/search or not) is currently active.
    public func collapseAll() {
        var set: Set<String> = []
        for root in roots { expand(root, toDepth: Self.defaultVisibleDepth, into: &set) }
        activeExpanded = set
        rebuild()
    }

    /// Expands every node shallower than `depth` that has children, leaving already-expanded
    /// deeper nodes alone. Acts on whichever view (filtered/search or not) is currently active.
    public func expandAll(toDepth depth: Int = ReportViewModel.deepVisibleDepth) {
        var set = activeExpanded
        for root in roots { expand(root, toDepth: depth, into: &set) }
        activeExpanded = set
        rebuild()
    }

    // MARK: - Internals

    private func expand(_ node: DirNode, toDepth depth: Int, into set: inout Set<String>) {
        guard node.row.depth < depth, !node.children.isEmpty else { return }
        set.insert(node.id)
        for c in node.children { expand(c, toDepth: depth, into: &set) }
    }

    private var isFiltering: Bool { filter != .all || !searchText.isEmpty }

    /// Rebuilds `filteredExpanded` from scratch so every ancestor of a match starts expanded: a
    /// node is auto-opened when at least one of its children (matching or not, since only shown
    /// children matter) has a match. Called whenever filtering turns on or the filter/search text
    /// changes, so each new filter always starts fully revealed.
    private func recomputeFilteredExpanded() {
        var cache: [String: Bool] = [:]
        var result: Set<String> = []
        func visit(_ node: DirNode) {
            guard hasMatch(node, cache: &cache) else { return }
            if node.children.contains(where: { hasMatch($0, cache: &cache) }) { result.insert(node.id) }
            for c in node.children { visit(c) }
        }
        for root in roots { visit(root) }
        filteredExpanded = result
    }

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
        let openIDs = activeExpanded

        func visit(_ node: DirNode) {
            if filtering && !hasMatch(node, cache: &cache) { return }
            let shownChildren = node.children.filter { !filtering || hasMatch($0, cache: &cache) }
            let open = !shownChildren.isEmpty && openIDs.contains(node.id)
            out.append(VisibleRow(node: node, isExpanded: open))
            guard open else { return }
            for c in shownChildren.sorted(by: less) { visit(c) }
        }
        for root in roots { visit(root) }
        visibleRows = out
    }
}
