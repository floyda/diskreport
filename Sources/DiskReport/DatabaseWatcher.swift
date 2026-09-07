import Darwin
import Foundation

/// Watches the data directory and the database file; calls `onChange` on the main queue, debounced.
final class DatabaseWatcher {
    private let directory: URL
    private let fileName: String
    private let onChange: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(directory: URL, fileName: String, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    func start() {
        let onDirEvent: () -> Void = { [weak self] in self?.schedule() }
        directorySource = watch(path: directory.path, events: [.write, .rename], onEvent: onDirEvent)
        armFileWatches()
    }

    /// Cancels any existing file watches and reopens them against the current inode for the database
    /// file and its -wal sidecar. Paths that don't exist yet (fresh install, or mid-rename) are
    /// silently skipped; the directory watch will trigger a re-arm once they appear.
    private func armFileWatches() {
        fileSources.forEach { $0.cancel() }
        fileSources.removeAll()

        let dbPath = directory.appendingPathComponent(fileName).path
        let walPath = directory.appendingPathComponent(fileName + "-wal").path
        let onFileEvent: () -> Void = { [weak self] in self?.schedule() }

        if let source = watch(path: dbPath, events: [.write, .extend, .rename, .delete], onEvent: onFileEvent) {
            fileSources.append(source)
        }
        if let source = watch(path: walPath, events: [.write, .extend, .rename, .delete], onEvent: onFileEvent) {
            fileSources.append(source)
        }
    }

    private func watch(
        path: String,
        events: DispatchSource.FileSystemEvent,
        onEvent: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.armFileWatches()
            self.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    deinit {
        directorySource?.cancel()
        fileSources.forEach { $0.cancel() }
    }
}
