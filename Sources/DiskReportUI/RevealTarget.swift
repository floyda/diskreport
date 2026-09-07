import Foundation

public enum RevealTarget {
    /// The folder itself. Passing this to `NSWorkspace.activateFileViewerSelecting` opens the parent in Finder
    /// with this folder selected, so Command-Delete acts on it immediately.
    public static func url(forFolder path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
