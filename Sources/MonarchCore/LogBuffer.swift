/// The newest log lines, kept in memory for the diagnostics report (fixed capacity: the
/// oldest line drops out when it's full).
public struct LogBuffer: Sendable {
    public let capacity: Int
    private var lines: [String] = []
    private var start = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ line: String) {
        if lines.count < capacity { lines.append(line) } else { lines[start] = line; start = (start + 1) % capacity }
    }

    /// Oldest first.
    public var all: [String] { Array(lines[start...] + lines[..<start]) }
    public var count: Int { lines.count }
}

public enum LogFormat {
    /// One log line: time, level, category, message (one line: newlines become " ⏎ ").
    public static func line(time: String, level: String, category: String, _ message: String) -> String {
        "\(time) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(category)] "
            + message.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    /// True when the log file should be rotated before writing more.
    public static func shouldRotate(size: UInt64, limit: UInt64) -> Bool { size >= limit }
}
