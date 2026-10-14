import Foundation

/// Gemini input includes cache hits; thoughts are additional output tokens.
struct GeminiCollector: Collector {
    let cli: CLIKind = .gemini
    var root: String {
        let configured = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.gemini"
        return URL(fileURLWithPath: configured).resolvingSymlinksInPath().path
    }

    func discoverPaths() -> [String] {
        FSWalk.files(under: root + "/tmp", ext: "json").filter {
            URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("session-")
                && URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent == "chats"
        }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    func collect(cache: ScanCache) -> [UsageBucket] {
        let paths = Set(discoverPaths()).union(cache.retainedPaths(under: root + "/tmp"))
        var events: [UsageEventRecord] = []
        for path in paths.sorted() {
            events += cache.events(for: path) { Self.scanEvents(path: path) }
        }
        return additionalBuckets(events, cli: cli)
    }

    static func scanEvents(path: String) -> [UsageEventRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        let session = obj["sessionId"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
        return messages.enumerated().compactMap { index, message in
            guard message["type"] as? String == "gemini",
                  let usage = message["tokens"] as? [String: Any],
                  let stamp = message["timestamp"] as? String,
                  let day = DayFormatter.day(fromISO: stamp) else { return nil }
            let input = max(0, intValue(usage["input"]))
            let cached = min(input, max(0, intValue(usage["cached"])))
            let counts = TokenCounts(input: input - cached,
                                     output: max(0, intValue(usage["output"])) + max(0, intValue(usage["thoughts"])),
                                     cacheRead: cached)
            guard counts.total > 0 else { return nil }
            let id = message["id"] as? String
            // UUID message IDs are global. Older numeric/short IDs are session scoped.
            let rid = id.flatMap { $0.isEmpty ? nil : $0 }.map {
                UUID(uuidString: $0) != nil ? "gemini:\($0)" : "gemini:\(session):\($0)"
            } ?? "gemini:\(session):\(index):\(stamp)"
            var event = UsageEventRecord(rid: rid, model: message["model"] as? String ?? "unknown",
                                         day: day, tokens: counts)
            event.provider = "google"
            return event
        }
    }
}

/// Shared event reduction preserves provider and cost provenance through grouping.
/// Taking maxima also handles migration copies containing an earlier snapshot.
func additionalBuckets(_ events: [UsageEventRecord], cli: CLIKind) -> [UsageBucket] {
    var unique: [String: UsageEventRecord] = [:]
    for event in events {
        let identity = cli == .magpie ? String(event.rid.split(separator: "\u{1}")[0]) : event.rid
        if var previous = unique[identity] {
            previous.tokens = previous.tokens.maxed(with: event.tokens)
            if let cost = event.reportedCostUSD {
                previous.reportedCostUSD = max(previous.reportedCostUSD ?? cost, cost)
                previous.costSource = event.costSource
            }
            unique[identity] = previous
        } else { unique[identity] = event }
    }
    return mergeBuckets(unique.values.map { event in
        var bucket = UsageBucket(origin: .local, cli: cli, model: event.model,
                                 day: event.day, tokens: event.tokens, isSidechain: event.isSidechain)
        bucket.provider = event.provider
        bucket.reportedCostUSD = event.reportedCostUSD
        bucket.costSource = event.costSource
        bucket.pricingTier = event.pricingTier
        bucket.serviceTier = event.serviceTier
        bucket.speed = event.speed
        bucket.inferenceGeo = event.inferenceGeo
        return bucket
    })
}
