import DiskReportCore
import Foundation

public enum TreeBuilder {
    /// One tree per report that has rows. Root nodes are named by full path, children by last path component.
    public static func build(_ reports: [RootReport]) -> [DirNode] {
        reports.compactMap { report in
            guard !report.rows.isEmpty else { return nil }
            var nodes: [String: DirNode] = [:]
            nodes.reserveCapacity(report.rows.count)
            for row in report.rows {
                let name = row.parentPath == nil ? row.path : (row.path as NSString).lastPathComponent
                nodes[row.path] = DirNode(row: row, name: name)
            }
            var root: DirNode?
            for row in report.rows {
                let node = nodes[row.path]!
                if let parentPath = row.parentPath, let parent = nodes[parentPath] {
                    parent.add(child: node)
                } else if row.parentPath == nil {
                    root = node
                }
            }
            guard let root else { return nil }
            root.sortChildrenRecursively { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return root
        }
    }
}
