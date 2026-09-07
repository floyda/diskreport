import DiskReportCore

public final class DirNode: Identifiable {
    public let id: String
    public let name: String
    public let row: ReportRow
    public private(set) var children: [DirNode] = []
    public private(set) weak var parent: DirNode?

    public init(row: ReportRow, name: String) {
        self.id = row.path
        self.name = name
        self.row = row
    }

    public func add(child: DirNode) {
        child.parent = self
        children.append(child)
    }

    func sortChildrenRecursively(by areInIncreasingOrder: (DirNode, DirNode) -> Bool) {
        children.sort(by: areInIncreasingOrder)
        for c in children { c.sortChildrenRecursively(by: areInIncreasingOrder) }
    }
}
