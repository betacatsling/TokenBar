import Foundation
import CryptoKit

struct MagpieScanDiagnostics: Codable {
    var ambiguousMirrors: Int = 0
    var joinedMirrors: Int = 0
    var malformedRecords: Int = 0
    var duplicateRecords: Int = 0
    var standaloneCalls: Int = 0
}

struct MagpieScanResult {
    var events: [UsageEventRecord]
    var diagnostics: MagpieScanDiagnostics
}

/// Gateway logs are mirrors by default. A missing match is NOT proof of a
/// standalone call: older CLI records often omit the gateway response ID.
struct MagpieCollector: Collector {
    let cli: CLIKind = .magpie
    var root: String {
        let configured = ProcessInfo.processInfo.environment["MAGPIE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.config/magpie"
        return URL(fileURLWithPath: configured).resolvingSymlinksInPath().path
    }
    var path: String { root + "/usage.jsonl" }

    func discoverPaths() -> [String] {
        FileManager.default.fileExists(atPath: path) ? [path] : []
    }

    func collect(cache: ScanCache) -> [UsageBucket] { collect(cache: cache, excluding: []) }

    /// Coverage can inspect this even on a cache hit; no provider config read.
    func scanDiagnostics(excluding: Set<String> = []) -> MagpieScanDiagnostics {
        Self.scan(path: path, excluding: excluding).diagnostics
    }

    /// Exclusion IDs are raw stable request/response IDs or r:/request:/response:
    /// prefixed IDs from existing collectors. Re-evaluate them on every scan.
    func collect(cache: ScanCache, excluding: Set<String>) -> [UsageBucket] {
        let paths = Set(discoverPaths()).union(cache.retainedPaths(under: root))
        var events: [UsageEventRecord] = []
        for file in paths.sorted() {
            events += cache.events(for: file) { Self.scanEvents(path: file) }
        }
        let filtered = events.filter { event in
            let identities = event.rid.dropFirst("magpie:".count).split(separator: "\u{1}")
            return !identities.contains { Self.matches(String($0), excluding: excluding) }
        }
        let stats = scanDiagnostics(excluding: excluding)
        if stats.ambiguousMirrors > 0 || stats.joinedMirrors > 0 {
            Self.diagnostic("excluded \(stats.ambiguousMirrors) ambiguous or CLI gateway mirrors; \(stats.joinedMirrors) joined mirrors")
        }
        return additionalBuckets(filtered, cli: cli)
    }

    static func matches(_ id: String, excluding: Set<String>) -> Bool {
        excluding.contains(id) || excluding.contains("r:" + id)
            || excluding.contains("request:" + id) || excluding.contains("response:" + id)
            || excluding.contains("magpie:" + id)
    }

    static func diagnostic(_ text: String) {
        FileHandle.standardError.write(Data(("Magpie: " + text + "\n").utf8))
    }

    static func scanEvents(path: String) -> [UsageEventRecord] {
        scan(path: path).events
    }

    /// Official intent-classifier calls use agent=magpie. Only this verified
    /// standalone agent type is counted. `req` is a model path, never an ID.
    /// Exact normalized record fingerprints dedup appended copies WITHIN this
    /// gateway log; they are never used for cross-source similarity joins.
    static func scan(path: String, excluding: Set<String> = []) -> MagpieScanResult {
        var events: [UsageEventRecord] = []
        var stats = MagpieScanDiagnostics()
        var seen = Set<String>()
        LineReader.forEachLine(path: path) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                stats.malformedRecords += 1
                return
            }
            let ids = ["response_id", "responseId", "request_id", "requestId"].compactMap { obj[$0] as? String }.filter { !$0.isEmpty }
            let agent = (obj["agent"] as? String ?? "").lowercased()
            if ids.contains(where: { matches($0, excluding: excluding) }) {
                stats.joinedMirrors += 1
                return
            }
            guard agent == "magpie",
                  let stamp = obj["t"] as? String, let day = DayFormatter.day(fromISO: stamp),
                  let model = (obj["served"] as? String) ?? (obj["model"] as? String), !model.isEmpty,
                  let provider = obj["provider"] as? String, !provider.isEmpty else {
                stats.ambiguousMirrors += 1
                return
            }
            guard let canonical = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            let fingerprint = "fingerprint:" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            let id = ids.first ?? fingerprint
            guard seen.insert(id).inserted else { stats.duplicateRecords += 1; return }
            let counts = TokenCounts(input: max(0, intValue(obj["in"])), output: max(0, intValue(obj["out"])),
                                     cacheRead: max(0, intValue(obj["cache_read"])),
                                     cacheWrite: max(0, intValue(obj["cache_write"])),
                                     cacheWrite1h: max(0, intValue(obj["cache_write_1h"])))
            guard counts.total > 0 else { return }
            var event = UsageEventRecord(rid: "magpie:" + ([id] + ids.dropFirst()).joined(separator: "\u{1}"),
                                         model: model, day: day, tokens: counts)
            event.provider = provider
            events.append(event)
            stats.standaloneCalls += 1
        }
        return MagpieScanResult(events: events, diagnostics: stats)
    }
}
