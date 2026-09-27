import Foundation

/// pi CLI: `$PI_CODING_AGENT_DIR/sessions/**/*.jsonl`
/// (`$PI_CODING_AGENT_DIR` defaults to `~/.pi/agent`).
///
/// Each assistant message carries a complete `usage` object with `input`,
/// `output`, `cacheRead`, `cacheWrite` — no streaming snapshots, no
/// session-cumulative totals — and `totalTokens` agrees exactly with the
/// component sum on this machine, so records are summed directly.
///
/// ## Why records dedup across files
///
/// pi transcripts get *copied*. An async/worker run mirrors its assistant
/// rows into `subagent-artifacts/*_transcript.jsonl`, and session forks copy
/// history verbatim — same `responseId`, same usage. Measured on this
/// machine's 219 files: 3,022 `responseId`s appear in more than one file,
/// every duplicate group carries byte-identical usage, and counting every
/// copy inflates pi's total by ~22.5% (205.9M duplicated tokens). Dedup is
/// therefore keyed on the globally stable `responseId`, with fallbacks for
/// rows that lack one:
///
/// - `responseId` — the gateway's id for the served response; copies share it.
/// - top-level entry `id` + usage signature — pi entry ids are copied
///   verbatim, and folding the usage in guards against collisions between
///   different rows that happen to share an 8-hex entry id.
/// - model+timestamp+usage signature — last resort for rows with neither id;
///   it can merge independent identical calls, but anything weaker keys
///   nothing and silently drops the row.
///
/// What dedup deliberately does NOT do is merge rows by identical usage
/// counts alone — two distinct calls can cost the same tokens.
struct PiCollector: Collector {
    let cli: CLIKind = .pi
    let origin: Origin = .local
    var root: String {
        let env = ProcessInfo.processInfo.environment
        return env["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.pi/agent"
    }

    func discoverPaths() -> [String] {
        FSWalk.files(under: root + "/sessions", ext: "jsonl")
    }

    func collect(cache: ScanCache) -> [UsageBucket] {
        var seen = Set<String>()
        var acc: [BucketKey: TokenCounts] = [:]
        // Sorted so the winner of a duplicated rid is deterministic. First
        // occurrence wins; measured copies carry byte-identical usage, so the
        // choice only fixes which timestamp family the day comes from.
        for path in discoverPaths().sorted() {
            for ev in cache.events(for: path, compute: { Self.scanEvents(path: path) }) {
                guard seen.insert(ev.rid).inserted else { continue }
                let key = BucketKey(origin: origin, cli: .pi, model: ev.model,
                                    day: ev.day, isSidechain: ev.isSidechain)
                acc[key, default: .zero] += ev.tokens
            }
        }
        return acc.map { key, tokens in
            UsageBucket(origin: key.origin, cli: key.cli, model: key.model,
                        day: key.day, tokens: tokens, isSidechain: key.isSidechain)
        }
    }

    /// One file's usage-bearing rows, at per-record granularity so the
    /// collector can collapse copies that live in sibling transcripts.
    static func scanEvents(path: String) -> [UsageEventRecord] {
        var events: [UsageEventRecord] = []
        var sessionModel: String?

        LineReader.forEachLine(path: path) { line in
            // Drain per line; see ClaudeCodeCollector for why this matters to RSS.
            autoreleasepool {
                // model_change carries the model for the whole session.
                if line.containsBytes(Needles.usage) {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any]
                    else { return }

                    let counts = TokenCounts(
                        input: intValue(usage["input"]),
                        output: intValue(usage["output"]),
                        cacheRead: intValue(usage["cacheRead"]),
                        // `cacheWrite1h` is the extended-TTL tier, billed
                        // separately but still cache-creation tokens. Rare here
                        // (1 event) yet free to fold in.
                        cacheWrite: intValue(usage["cacheWrite"]) + intValue(usage["cacheWrite1h"])
                    )
                    guard counts.total > 0 else { return }

                    // `responseModel` is what the gateway actually served;
                    // `model` is only what was requested. pi routes through
                    // proxies that substitute freely — measured here, 120 events
                    // requested `x-preview-f-free` and were served
                    // `ox-alpha-free`, 10.5% of pi's tokens. Attributing those to
                    // the requested name would price the wrong model and hide the
                    // substitution entirely.
                    let model = (message["responseModel"] as? String)
                        ?? (message["modelId"] as? String)
                        ?? (message["model"] as? String)
                        ?? (message["provider"] as? String)
                        ?? sessionModel
                        ?? "unknown"
                    let tsStr = obj["timestamp"] as? String ?? ""
                    let day = DayFormatter.day(fromISO: tsStr) ?? DayFormatter.today()

                    // Cross-file dedup identity. `responseId` is assigned by the
                    // gateway and copied with the row; entry `id` is copied too
                    // but is only 8 hex chars, so it keeps the usage signature
                    // as a collision guard. Timestamp is deliberately excluded
                    // from the entry-id fallback — measured copies re-stamp it.
                    let sig = "\(counts.input)/\(counts.output)/\(counts.cacheRead)/\(counts.cacheWrite)"
                    let rid: String
                    if let r = message["responseId"] as? String, !r.isEmpty {
                        rid = "r:\(r)"
                    } else if let e = obj["id"] as? String, !e.isEmpty {
                        rid = "e:\(e):\(sig)"
                    } else {
                        rid = "s:\(model):\(tsStr):\(sig)"
                    }

                    events.append(UsageEventRecord(rid: rid, model: model, day: day,
                                                   isSidechain: false, tokens: counts))
                } else if line.containsBytes(Array("\"model_change\"".utf8)),
                          let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let m = obj["modelId"] as? String, !m.isEmpty {
                    sessionModel = m
                }
            }
        }

        return events
    }
}
