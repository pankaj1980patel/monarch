import Foundation
import MonarchCore

/// Reads and writes ~/Library/Application Support/Monarch/config.json.
enum ConfigurationStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Monarch", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Reads config.json (see `ConfigFile`). Writes the defaults only when there is no file.
    /// A file that can't be read or parsed is kept as it is, and a copy is saved next to it
    /// as config.json.bad.
    static func read() -> ConfigFile.Outcome {
        let url = self.url
        let o = ConfigFile.interpret(exists: FileManager.default.fileExists(atPath: url.path),
                                     data: try? Data(contentsOf: url))
        switch o {
        case .missing: save(AppConfiguration())
        case .invalid:
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.copyItem(at: url, to: bad)
        case .loaded, .unreadable: break
        }
        return o
    }

    /// The configuration to use and the problem to report, if any.
    static func load() -> (AppConfiguration, error: String?) { ConfigFile.resolve(read()) }

    /// Sets only these keys in the file on disk (see `ConfigFile.patch`). False, and nothing
    /// written, when the file can't be read or isn't valid JSON.
    @discardableResult
    static func update(_ changes: [String: Bool]) -> Bool {
        let url = self.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let data = ConfigFile.patch(exists ? try? Data(contentsOf: url) : nil, exists: exists, changes: changes) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func save(_ c: AppConfiguration) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
