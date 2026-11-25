import Foundation

/// Calls `onChange` (on main, debounced) when a file is written. Watches the file's folder,
/// because editors and Monarch itself save atomically (a new file replaces the old one).
/// Kernel file events: nothing runs while nothing changes.
final class FileWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject?
    private let url: URL
    private var lastStamp: Date?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source = src
        lastStamp = Self.stamp(url)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.stamp(self.url)
            guard now != nil, now != self.lastStamp else { return }      // another file in the folder
            self.lastStamp = now
            self.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
    }

    private static func stamp(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    deinit { source?.cancel() }
}
