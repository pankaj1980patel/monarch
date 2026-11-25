import Foundation
import MonarchCore

/// Reads and writes ~/Library/Application Support/Monarch/config.json.
enum ConfigurationStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Monarch", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Loads the config, writing the defaults on first run. A broken file is reported, not overwritten.
    static func load() -> (AppConfiguration, error: String?) {
        let url = self.url
        guard let data = try? Data(contentsOf: url) else {
            let c = AppConfiguration()
            save(c)
            return (c, nil)
        }
        do { return (try JSONDecoder().decode(AppConfiguration.self, from: data), nil) }
        catch { return (AppConfiguration(), "config.json could not be read, using defaults: \(error.localizedDescription)") }
    }

    static func save(_ c: AppConfiguration) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
