import Darwin
import Foundation

/// Watches the data directory and the database file; calls `onChange` on the main queue, debounced.
final class DatabaseWatcher {
    private let directory: URL
    private let fileName: String
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(directory: URL, fileName: String, onChange: @escaping () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    func start() {
        watch(path: directory.path, events: [.write, .rename])
        watch(path: directory.appendingPathComponent(fileName).path, events: [.write, .extend, .rename, .delete])
        watch(path: directory.appendingPathComponent(fileName + "-wal").path, events: [.write, .extend])
    }

    private func watch(path: String, events: DispatchSource.FileSystemEvent) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    deinit { sources.forEach { $0.cancel() } }
}
