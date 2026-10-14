import Foundation
import SQLite3

struct OpenCodeCollector: Collector {
    let cli: CLIKind = .opencode
    var root: String {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.local/share"
        return URL(fileURLWithPath: data + "/opencode").resolvingSymlinksInPath().path
    }
    var dbPath: String { root + "/opencode.db" }

    func discoverPaths() -> [String] {
        let legacy = FSWalk.files(under: root + "/storage/message", ext: "json").map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        return legacy + (FileManager.default.fileExists(atPath: dbPath) ? [dbPath] : [])
    }

    func collect(cache: ScanCache) -> [UsageBucket] {
        let paths = Set(discoverPaths()).union(cache.retainedPaths(under: root))
        var events: [UsageEventRecord] = []
        // Prefer the migrated DB's metadata, but dedup IDs across both stores.
        for path in paths.sorted(by: { a, b in
            if a == dbPath { return b != dbPath }
            if b == dbPath { return false }
            return a < b
        }) {
            let sidecars = path == dbPath ? [path + "-wal", path + "-shm", path + "-journal"] : []
            events += cache.events(for: path, sidecars: sidecars) {
                path == dbPath ? Self.scanDatabase(path: path) : Self.scanLegacy(path: path)
            }
        }
        return additionalBuckets(events, cli: cli)
    }

    static func scanLegacy(path: String) -> [UsageEventRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = event(obj, fallbackID: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        else { return [] }
        return [event]
    }

    static func scanDatabase(path: String) -> [UsageEventRecord] {
        var db: OpaquePointer?
        // file URL encoding protects literal ?, #, %, and Unicode in XDG paths.
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let result = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, data FROM message ORDER BY id", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var events: [UsageEventRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                guard let blob = sqlite3_column_text(stmt, 1),
                      let data = String(cString: blob).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                if let event = event(obj, fallbackID: id) { events.append(event) }
            }
        }
        return events
    }

    static func event(_ obj: [String: Any], fallbackID: String? = nil) -> UsageEventRecord? {
        guard obj["role"] as? String == "assistant",
              let usage = obj["tokens"] as? [String: Any],
              let id = (obj["id"] as? String) ?? fallbackID, !id.isEmpty,
              let time = obj["time"] as? [String: Any],
              let stamp = (time["created"] as? NSNumber)?.doubleValue, stamp > 0 else { return nil }
        let modelObject = obj["model"] as? [String: Any]
        let model = obj["modelID"] as? String ?? modelObject?["modelID"] as? String ?? "unknown"
        let provider = obj["providerID"] as? String ?? modelObject?["providerID"] as? String
        let cache = usage["cache"] as? [String: Any] ?? [:]
        let input = max(0, intValue(usage["input"]))
        let read = max(0, intValue(cache["read"]))
        let write = max(0, intValue(cache["write"]))
        let oneHour = max(0, intValue(cache["write1h"]))
        var output = max(0, intValue(usage["output"]))
        let total = intValue(usage["total"])
        // The recorded total resolves whether reasoning is included in output.
        if total > 0 {
            output = max(0, total - input - read - write - oneHour)
        } else if provider?.lowercased().contains("openai") != true {
            output += max(0, intValue(usage["reasoning"]))
        }
        let counts = TokenCounts(input: input, output: output, cacheRead: read,
                                 cacheWrite: write, cacheWrite1h: oneHour)
        guard counts.total > 0 else { return nil }
        var event = UsageEventRecord(rid: "opencode:\(id)", model: model,
                                     day: DayFormatter.day(fromUnixSeconds: stamp / 1000), tokens: counts)
        event.provider = provider
        if let cost = (obj["cost"] as? NSNumber)?.doubleValue, cost.isFinite,
           cost > 0 || (cost == 0 && (model.lowercased().hasSuffix("-free") || model.lowercased().hasSuffix(":free"))) {
            event.reportedCostUSD = cost
            event.costSource = "reported"
        }
        return event
    }
}
