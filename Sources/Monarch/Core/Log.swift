import Foundation
import MonarchCore
import os
import Synchronization

/// Monarch's log: every line goes to the unified log (subsystem dev.monarch.Monarch, see it in
/// Console.app or with `log show --predicate 'subsystem == "dev.monarch.Monarch"'`), to
/// ~/Library/Logs/Monarch/monarch.log (kept across crashes and restarts, rotated at 1 MB to
/// monarch.1.log), and to an in-memory buffer for the diagnostics report.
///
/// Events only, never per frame or per mouse move. No window titles (they can be private):
/// apps by name, windows by id.
enum Log {
    enum Category: String, CaseIterable { case app, config, hotkeys, workspaces, gestures, focus, switcher, displays }

    static func info(_ c: Category, _ message: @autoclosure () -> String) { write(.info, c, message()) }
    static func notice(_ c: Category, _ message: @autoclosure () -> String) { write(.notice, c, message()) }
    static func error(_ c: Category, _ message: @autoclosure () -> String) { write(.error, c, message()) }

    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Monarch", isDirectory: true)
    }
    static var fileURL: URL { folder.appendingPathComponent("monarch.log") }

    /// The newest lines (oldest first), for the diagnostics report.
    static func recent() -> [String] { buffer.withLock { $0.all } }

    // MARK: Internals

    private enum Level: String { case info, notice = "note", error }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: "dev.monarch.Monarch", category: $0.rawValue))
    })
    private static let buffer = Mutex(LogBuffer(capacity: 400))
    private static let queue = DispatchQueue(label: "dev.monarch.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?     // queue only
    private static let limit: UInt64 = 1 << 20

    private static func write(_ level: Level, _ c: Category, _ message: String) {
        let logger = loggers[c]!
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = LogFormat.line(time: timestamp(), level: level.rawValue, category: c.rawValue, message)
        buffer.withLock { $0.append(line) }
        queue.async { append(line + "\n") }
    }

    private static func timestamp() -> String {
        var t = timespec(); clock_gettime(CLOCK_REALTIME, &t)
        var tm = tm(); var secs = t.tv_sec; localtime_r(&secs, &tm)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, Int(t.tv_nsec / 1_000_000))
    }

    /// Queue only.
    private static func append(_ text: String) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        if let size = try? h.offset(), LogFormat.shouldRotate(size: size, limit: limit) {
            try? h.close(); handle = nil
            let old = folder.appendingPathComponent("monarch.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
            append(text)
            return
        }
        h.write(Data(text.utf8))
    }

    /// Waits until queued lines are written (quitting).
    static func flush() { queue.sync { try? handle?.synchronize() } }
}
