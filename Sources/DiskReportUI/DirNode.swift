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

/// A tree is built by `TreeBuilder` on a background task and then handed to the main actor exclusively:
/// the building task drops every reference the moment it returns the roots, and nothing mutates a node
/// afterwards. That is a transfer of ownership the compiler cannot see, so it is asserted here rather than
/// paying for a class-wide lock on a type whose whole job is to be read from one actor.
extension DirNode: @unchecked Sendable {}
