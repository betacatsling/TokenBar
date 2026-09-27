import Foundation

/// Codex CLI: `$CODEX_HOME/sessions/**/*.jsonl` plus
/// `$CODEX_HOME/archived_sessions/` (`$CODEX_HOME` defaults to `~/.codex`).
///
/// ## Why usage is a lineage over cumulative snapshots, not `sum(last)`
///
/// The first implementation summed each event's `last_token_usage`. Three
/// measured failure modes, all confirmed against this machine's rollouts and
/// against usageBar's `CodexLineage` analysis:
///
/// 1. **Forked rollouts replay parent history.** A forked or subagent rollout
///    opens by copying the parent's entire `token_count` sequence. Charging
///    every copied `last` bills the parent's usage twice — measured at 76.9%
///    of a fork file's content. A 1-second-gap heuristic suppressed the burst,
///    but it both dropped a child's genuine first turn when it landed quickly
///    and leaked parent rows replayed slowly. The lineage gates on the
///    *cumulative* instead: a fork's watermarks start at the parent's
///    historical maximum, so every replayed row sits at or below the peak and
///    charges nothing, however fast or slow the copy ran.
///
/// 2. **`last` itself is inflated on older versions.** Pre-0.142 Codex wrote
///    `last_token_usage` values up to ~2x the real increment (measured: naive
///    sum 1,813,911,679 vs lineage 1,705,546,878 — 6.4% over; individual
///    rollouts reach 2.95x). The lineage charges `min(last, cumulative
///    advance)`, falling back to the componentwise diff when `last` lies.
///
/// 3. **Compaction/resume restarts the counter.** `total_token_usage` drops to
///    this-turn's value mid-file (84,966,808 → 80,949 is one observed reset).
///    A restart is recognised — and watermarks reset — only when `last` equals
///    the new cumulative; any other regression is a stale or out-of-order
///    write and is skipped without touching state, so a replayed old row can
///    never masquerade as a restart.
///
/// Inherited baselines inside the file (`last == 0`, positive cumulative) lift
/// the watermarks without charging — the shape of a fork's replayed tail and
/// of summary rows that carry only `total`.
///
/// See `CodexLineage` for the reducer and `ScanCache.resumable` for how the
/// scan resumes mid-file with these watermarks persisted.
struct CodexCollector: Collector {
    let cli: CLIKind = .codex
    let origin: Origin = .local

    var roots: [String] {
        let env = ProcessInfo.processInfo.environment
        let base = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        return [base + "/sessions", base + "/archived_sessions"]
    }

    /// The identity a rollout keeps even when Codex moves it between
    /// `sessions/` and `archived_sessions/` — the same session can live in
    /// either directory, so both are scanned but a name found in both is
    /// counted once.
    private struct RolloutCandidate {
        var path: String
        var isArchived: Bool
        var mtime: Double
        var size: UInt64
    }

    /// Facts from a file's own `session_meta`, needed before the scan to pick
    /// a fork baseline.
    struct SessionMeta {
        var ownId: String
        var forkedFromId: String?
        var isSubagent: Bool
    }

    /// Enumerate `rollout-*.jsonl` under both roots, deduplicate by basename,
    /// and sort by basename so a parent is always processed before its forks
    /// (filenames embed an ISO timestamp, so lexical order is birth order).
    static func rolloutFiles(roots: [String]) -> [String] {
        var best: [String: RolloutCandidate] = [:]
        for (index, root) in roots.enumerated() {
            for path in FSWalk.files(under: root, ext: "jsonl") {
                let name = (path as NSString).lastPathComponent
                guard name.hasPrefix("rollout-") else { continue }
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let candidate = RolloutCandidate(
                    path: path,
                    isArchived: index > 0,
                    mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                    size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                )
                // A file moved sessions->archived keeps its name; keep the
                // newer/bigger copy, preferring the active directory on a tie.
                if let existing = best[name] {
                    let better = candidate.mtime > existing.mtime
                        || (candidate.mtime == existing.mtime
                            && (candidate.size > existing.size
                                || (candidate.size == existing.size && !candidate.isArchived)))
                    if better { best[name] = candidate }
                } else {
                    best[name] = candidate
                }
            }
        }
        return best.values.sorted {
            ($0.path as NSString).lastPathComponent < ($1.path as NSString).lastPathComponent
        }.map(\.path)
    }

    func discoverPaths() -> [String] {
        Self.rolloutFiles(roots: roots)
    }

    func collect(cache: ScanCache) -> [UsageBucket] {
        var out: [UsageBucket] = []
        /// session id -> the file's historical max cumulative. A fork looks up
        /// its parent here to start its watermarks past the replayed history.
        var sessionFinal: [String: CodexUsageVec] = [:]

        for path in discoverPaths() {
            let meta = Self.probeMeta(path: path)
            let baseline = Self.baseline(for: meta, sessionFinal: sessionFinal)
            let outcome = cache.resumable(for: path, baseline: baseline) { point in
                Self.scan(path: path, origin: origin, resume: point, baseline: baseline)
            }
            out += outcome.buckets
            if let state = outcome.state, !state.sessionId.isEmpty {
                sessionFinal[state.sessionId] =
                    (sessionFinal[state.sessionId] ?? .zero).componentMax(state.maxTotal)
            }
        }
        return mergeBuckets(out)
    }

    /// Baseline a fork should start from: the parent's historical max, unless
    /// the file is a subagent thread — subagent usage is not part of the
    /// parent's accounting, so subtracting it would zero the whole file.
    static func baseline(for meta: SessionMeta?,
                         sessionFinal: [String: CodexUsageVec]) -> CodexUsageVec? {
        guard let meta, !meta.isSubagent,
              let parent = meta.forkedFromId,
              let final = sessionFinal[parent], final.total > 0 else { return nil }
        return final
    }

    /// Read just enough of the head to find the file's own `session_meta`.
    /// Fork decisions must be made before the scan, and the meta is always
    /// among the first lines, so this never touches the bulk of a rollout.
    static func probeMeta(path: String) -> SessionMeta? {
        var found: SessionMeta?
        var read = 0
        LineReader.forEachLineWhile(path: path) { line in
            read += line.count + 1
            if line.containsBytes(Needles.sessionMeta),
               let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               obj["type"] as? String == "session_meta",
               let payload = obj["payload"] as? [String: Any] {
                found = sessionMeta(from: payload)
                return false
            }
            return read < (256 << 10)
        }
        return found
    }

    /// Extract identity from a `session_meta` payload.
    ///
    /// `payload.source` is a plain string in ordinary rollouts (`"vscode"`) and
    /// an object in subagent ones, so it must be type-checked before reading
    /// through it.
    static func sessionMeta(from payload: [String: Any]) -> SessionMeta {
        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let threadSource = payload["thread_source"] as? String
        return SessionMeta(
            ownId: (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? "",
            forkedFromId: (payload["forked_from_id"] as? String)
                ?? (spawn?["parent_thread_id"] as? String),
            isSubagent: subagent != nil
                || threadSource == "subagent" || threadSource == "guardian_review"
        )
    }

    /// Parse a rollout, resuming from `resume` when the caller has one.
    ///
    /// `baseline` primes the lineage watermarks for a fresh parse; a resumed
    /// parse keeps whatever the earlier scan recorded — the reducer checks it
    /// agrees and restarts from byte 0 if the offered baseline changed.
    ///
    /// Returns nil only when the file cannot be read from `resume.startOffset`,
    /// so the caller can tell a read failure from a genuinely empty file.
    static func scan(path: String, origin: Origin, resume: ResumePoint,
                     baseline: CodexUsageVec? = nil) -> ResumedBuckets? {
        // A resume point is only usable while the baseline it was computed
        // under still holds; otherwise the honest thing is a re-parse from
        // byte 0, since an offset-state built on a different baseline cannot
        // be adjusted.
        let resumeOK = resume.startOffset == 0
            || (resume.state != nil
                && (resume.state!.baselineUsed ?? .zero) == (baseline ?? .zero))
        var state: CodexScanState
        if resumeOK, let resumed = resume.state, resume.startOffset > 0 {
            state = resumed
        } else {
            state = CodexScanState()
            state.applyBaseline(baseline)
        }
        let startOffset = resumeOK ? resume.startOffset : 0
        var acc: [BucketKey: TokenCounts] = [:]

        // A resumed parse is handed only the reducer state: the caller already
        // holds the buckets from before `startOffset` and concatenates them, so
        // only lines at or after that offset are seen here.

        func handle(_ line: Data) {
            guard line.containsAnyBytes(Needles.codexRelevant) else { return }
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { return }
                reduce(obj: obj, payload: payload, state: &state, origin: origin, acc: &acc)
            }
        }

        guard let result = LineScanner.scan(path: path, from: startOffset, handle) else {
            return nil
        }

        // The trailing segment has no newline yet: the writer may still be
        // extending it. Parse it so the current refresh shows it, but do not
        // advance past it — otherwise the next scan reads it again and counts it
        // twice.
        if let tail = result.tail, !tail.isEmpty,
           tail.containsAnyBytes(Needles.codexRelevant) {
            var tailState = state
            var tailAcc: [BucketKey: TokenCounts] = [:]
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: tail) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { return }
                reduce(obj: obj, payload: payload, state: &tailState, origin: origin, acc: &tailAcc)
            }
            let tailBuckets = tailAcc.map { key, tokens in
                UsageBucket(origin: key.origin, cli: key.cli, model: key.model,
                            day: key.day, tokens: tokens, isSidechain: key.isSidechain)
            }
            let guardInfo = ScanCache.guardWindow(for: path, endingAt: result.resumeOffset)
            return ResumedBuckets(
                buckets: acc.map { UsageBucket(origin: $0.key.origin, cli: $0.key.cli,
                                               model: $0.key.model, day: $0.key.day,
                                               tokens: $0.value, isSidechain: $0.key.isSidechain) },
                tailBuckets: tailBuckets,
                position: ScanPosition(resumeOffset: result.resumeOffset,
                                       guardLength: guardInfo.length,
                                       guardHash: guardInfo.hash),
                state: state
            )
        }

        let guardInfo = ScanCache.guardWindow(for: path, endingAt: result.resumeOffset)
        return ResumedBuckets(
            buckets: acc.map { UsageBucket(origin: $0.key.origin, cli: $0.key.cli,
                                           model: $0.key.model, day: $0.key.day,
                                           tokens: $0.value, isSidechain: $0.key.isSidechain) },
            tailBuckets: [],
            position: ScanPosition(resumeOffset: result.resumeOffset,
                                   guardLength: guardInfo.length,
                                   guardHash: guardInfo.hash),
            state: state
        )
    }

    /// Feed one decoded line into the reducer.
    private static func reduce(obj: [String: Any],
                               payload: [String: Any],
                               state: inout CodexScanState,
                               origin: Origin,
                               acc: inout [BucketKey: TokenCounts]) {
        switch obj["type"] as? String {
        case "session_meta":
            // Only the first meta describes this file's own session. A forked
            // rollout repeats its ancestors' metas right after it, and letting
            // those through would reassign every later record to an ancestor.
            guard !state.sawSessionMeta else { return }
            state.sawSessionMeta = true
            let meta = sessionMeta(from: payload)
            state.sessionId = meta.ownId
            state.forkedFromId = meta.forkedFromId
            state.isSubagent = meta.isSubagent
            return

        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            return

        default:
            break
        }

        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }

        var total = usageVec(info["total_token_usage"])
        let last = usageVec(info["last_token_usage"])
        if total == nil, let l = last, l.total > 0 {
            // Rows without a cumulative (legacy/foreign writers) synthesize one
            // from the running peak so the normal lineage path handles them.
            total = state.peak + l
        }
        guard let t = total,
              let delta = CodexLineage.advance(&state, total: t, last: last) else { return }

        let counts = TokenCounts(
            input: delta.input - delta.cached,
            output: delta.output,
            cacheRead: delta.cached,
            cacheWrite: 0
        )
        guard counts.total > 0 else { return }

        // `token_count` carries no model of its own: prefer a per-event model
        // when present, else the model carried forward from `turn_context`.
        // Usage seen before any model is attributed to `unknown` rather than
        // dropped — the tokens are real regardless of labelling.
        let model = (payload["model"] as? String)
            ?? (info["model"] as? String)
            ?? (info["model_name"] as? String)
            ?? (state.model.isEmpty ? "unknown" : state.model)

        // Subagent threads are normal usage: `isSubagent` steers only the
        // fork-baseline decision (their counter is independent of the
        // parent's). usageBar and tokscale both bill it — it is real usage,
        // not excludable sidechain traffic like Claude's native flag.
        let key = BucketKey(origin: origin, cli: .codex, model: model,
                            day: DayFormatter.day(fromISO: obj["timestamp"] as? String ?? "")
                                ?? DayFormatter.today(),
                            isSidechain: false)
        acc[key, default: .zero] += counts
    }

    /// Decode a usage object into the 4-component cumulative vector.
    ///
    /// Accepts the two spellings Codex has used for the cached subset, and
    /// falls back to `total_tokens` alone when the components are absent
    /// (degraded rows still carry a scalar total).
    static func usageVec(_ raw: Any?) -> CodexUsageVec? {
        guard let u = raw as? [String: Any] else { return nil }
        if u["input_tokens"] != nil || u["output_tokens"] != nil {
            return CodexUsageVec(
                input: intValue(u["input_tokens"]),
                cached: max(intValue(u["cached_input_tokens"]),
                            intValue(u["cache_read_input_tokens"])),
                output: intValue(u["output_tokens"]),
                reasoning: intValue(u["reasoning_output_tokens"]))
        }
        if u["total_tokens"] != nil {
            return CodexUsageVec(input: intValue(u["total_tokens"]))
        }
        return nil
    }
}
