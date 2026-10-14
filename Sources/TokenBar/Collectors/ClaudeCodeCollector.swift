import Foundation

/// Claude Code: `$CLAUDE_CONFIG_DIR/projects/**/*.jsonl`
/// (`$CLAUDE_CONFIG_DIR` defaults to `~/.claude`).
///
/// Critical detail — the transcript contains *progressive streaming snapshots*
/// of the same assistant message. Measured on this machine: of 999 unique
/// `message.id` values, 716 appear multiple times with growing token counts
/// (e.g. output 1 → 1 → 279) and 46 appear as exact duplicates. Naively summing
/// every `usage` object inflates the total by roughly 2x.
///
/// Dedup therefore works on two levels:
///
/// - **Within a file**, records group by `messageId:requestId` — the composite
///   tokscale and ccusage both key on. `requestId` is present on older
///   transcripts (absent entirely from this machine's newer writer, where the
///   key degrades to `message:{id}`), and including it matters because a
///   *retried* request reuses `message.id`: keying on the id alone would
///   merge two real calls into one.
/// - **Across files**, `claude --resume` and `--fork-session` write a new
///   transcript containing the parent's rows verbatim. The copies carry
///   identical composite keys, so the same merge collapses them rather than
///   billing the replayed history again. Per-file buckets cannot express
///   this; per-record events can. For each key the per-field *maximum* is
///   kept — a streaming snapshot only ever grows, so the max recovers the
///   message's final usage no matter which copy survives.
///
/// Files literally named `journal.jsonl` under any `subagents/` directory are
/// excluded: Claude Code writes them alongside `agent-*.jsonl` transcripts to
/// record workflow orchestration (`started`/`result` events, no usage rows).
/// They parse to zero today but are dropped explicitly so a future schema
/// change can't leak token-shaped fields.
struct ClaudeCodeCollector: Collector {
    let cli: CLIKind = .claudeCode
    let origin: Origin = .local
    var root: String {
        let env = ProcessInfo.processInfo.environment
        let base = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.claude"
        return base + "/projects"
    }

    func discoverPaths() -> [String] {
        FSWalk.files(under: root, ext: "jsonl").filter { !Self.isWorkflowJournal($0) }
    }

    /// `.../<session>/subagents/**/journal.jsonl` — orchestration metadata,
    /// not a message transcript.
    static func isWorkflowJournal(_ path: String) -> Bool {
        guard (path as NSString).lastPathComponent == "journal.jsonl" else { return false }
        var component = (path as NSString).deletingLastPathComponent
        while component.count > 1 {
            if (component as NSString).lastPathComponent == "subagents" { return true }
            component = (component as NSString).deletingLastPathComponent
        }
        return false
    }

    func collect(cache: ScanCache) -> [UsageBucket] {
        // Composite key -> max-so-far. Merging by per-field max rather than
        // first-wins: a streaming snapshot sequence split across a copied
        // transcript still recovers the message's final usage, and copies are
        // byte-identical so the merge is a no-op for them.
        var best: [String: UsageEventRecord] = [:]
        let canonical = root.withCString { pointer -> String in
            guard let path = realpath(pointer, nil) else { return root }
            defer { free(path) }
            return String(cString: path)
        }
        let retained = cache.retainedPaths(under: root) + cache.retainedPaths(under: canonical)
        for path in Set(discoverPaths() + retained).sorted() where !Self.isWorkflowJournal(path) {
            for ev in cache.events(for: path, compute: { Self.scanEvents(path: path) }) {
                if let existing = best[ev.rid] {
                    // Keep the first record's slot (model/day/sidechain) —
                    // copies share it verbatim — but take the field-wise max
                    // of the counts.
                    best[ev.rid] = existing.mergingSnapshot(with: ev)
                } else {
                    best[ev.rid] = ev
                }
            }
        }
        return mergeBuckets(best.values.map { $0.bucket(origin: origin, cli: .claudeCode) })
    }

    /// One file's usage-bearing rows at per-record granularity. Within the
    /// file the composite key already collapses streaming snapshots by
    /// per-field max — the same operation the collector then applies across
    /// files.
    static func scanEvents(path: String) -> [UsageEventRecord] {
        var best: [String: UsageEventRecord] = [:]
        var order: [String] = []

        LineReader.forEachLine(path: path) { line in
            guard line.containsBytes(Needles.usage) else { return }
            // Per-line autorelease pool: JSONSerialization hands back autoreleased
            // Foundation objects, and without draining one per line the parsed
            // dictionaries from every transcript pile up until the outer pool
            // empties, inflating peak RSS during a full scan.
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }

                let creation = usage["cache_creation"] as? [String: Any]
                let write1h = intValue(creation?["ephemeral_1h_input_tokens"] ?? usage["cache_creation_1h_input_tokens"])
                let counts = TokenCounts(
                    input: intValue(usage["input_tokens"]),
                    output: intValue(usage["output_tokens"]),
                    cacheRead: intValue(usage["cache_read_input_tokens"]),
                    cacheWrite: creation?["ephemeral_5m_input_tokens"] != nil
                        ? intValue(creation?["ephemeral_5m_input_tokens"])
                        : max(0, intValue(usage["cache_creation_input_tokens"]) - write1h),
                    cacheWrite1h: write1h
                )
                guard counts.total > 0 else { return }

                let model = (message["model"] as? String) ?? "unknown"
                // Synthetic entries are local bookkeeping, not real API calls.
                guard model != "<synthetic>" else { return }

                let day = (obj["timestamp"] as? String).flatMap(DayFormatter.day(fromISO:)) ?? DayFormatter.today()
                let sidechain = (obj["isSidechain"] as? Bool) ?? false

                // tokscale's composite: a request retried under the same
                // message id must not merge into the first call. Rows lacking
                // both ids fall back to `uuid`, which copies also preserve.
                let key: String
                if let mid = message["id"] as? String {
                    if let rid = obj["requestId"] as? String, !rid.isEmpty {
                        key = "\(mid):\(rid)"
                    } else {
                        key = "message:\(mid)"
                    }
                } else {
                    key = "uuid:\((obj["uuid"] as? String) ?? UUID().uuidString)"
                }

                var event = UsageEventRecord(rid: key, model: model, day: day,
                                             isSidechain: sidechain, tokens: counts)
                event.applyMetadata([usage, message, obj])
                if let existing = best[key] {
                    best[key] = existing.mergingSnapshot(with: event)
                } else {
                    order.append(key)
                    best[key] = event
                }
            }
        }

        return order.compactMap { best[$0] }
    }
}
