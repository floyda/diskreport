/// Cheap summary of a directory's immediate children, passed to classifiers.
public struct DirectoryEntrySummary: Sendable {
    public var childNames: [String]
    public init(childNames: [String]) { self.childNames = childNames }
}

/// Extension point: label directories (e.g. "node_modules", "venv", "git", "build", "archive").
/// v1 ships only `NoClassifier`.
public protocol DirectoryClassifier: Sendable {
    func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String?
}

public struct NoClassifier: DirectoryClassifier {
    public init() {}
    public func classify(path: String, name: String, entries: DirectoryEntrySummary) -> String? { nil }
}
