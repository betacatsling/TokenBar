import Foundation
import CryptoKit
import Darwin

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
///    copied event identities instead. A parent's later usage does not define
///    the fork boundary; inherited events still advance the child's counter
///    state, including any copied counter resets, without being billed.
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
///    cannot masquerade as a restart when its recorded identity was seen before.
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
    /// and sort by basename for stable output. Parent identity lookup is a
    /// separate pass and never relies on this order.
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
        let live = discoverPaths()
        var names = Set(live.map { ($0 as NSString).lastPathComponent })
        var paths = live
        for root in roots {
            // FSWalk resolves macOS /var -> /private/var symlinks. Match
            // retained paths under both spellings, including when files vanish.
            let canonical = Self.canonicalRoot(root)
            for path in cache.retainedPaths(under: root) + cache.retainedPaths(under: canonical) {
                if names.insert((path as NSString).lastPathComponent).inserted { paths.append(path) }
            }
        }
        var histories: [String: Set<String>] = [:]
        var outcomes: [String: ResumableOutcome] = [:]
        var metas: [String: SessionMeta] = [:]
        // Index every parent before attributing any fork. Filename order and
        // the parent's later counter maximum do not determine a fork boundary.
        for path in paths {
            let retained = cache.retainedState(for: path)
            let meta = Self.probeMeta(path: path) ?? retained.map {
                SessionMeta(ownId: $0.sessionId, forkedFromId: $0.forkedFromId, isSubagent: $0.isSubagent)
            }
            metas[path] = meta
            let isFork = meta?.forkedFromId != nil && meta?.isSubagent == false
            let dependency = isFork ? retained?.baselineUsed : nil
            let outcome = cache.resumable(for: path, baseline: dependency) { point in
                Self.scan(path: path, origin: origin, resume: point,
                          baseline: dependency,
                          replayIdentities: isFork ? (retained?.replaySourceIdentities ?? []) : nil)
            }
            outcomes[path] = outcome
            if let state = outcome.state, !state.sessionId.isEmpty {
                histories[state.sessionId, default: []].formUnion(state.replayIdentities)
            }
        }
        for path in paths {
            if let meta = metas[path], !meta.isSubagent, let parent = meta.forkedFromId,
               FileManager.default.fileExists(atPath: path) {
                // Re-evaluate against retained/live parent identities. This
                // avoids reusing buckets after a previously missing parent appears.
                let identities = histories[parent] ?? []
                // The existing baseline cache key is a dependency fingerprint
                // here, never a cumulative watermark. Sorted identities make
                // it stable across launch/order and retained-history changes.
                let digest = Array(SHA256.hash(data: Data(identities.sorted().joined(separator: "\n").utf8)))
                func word(_ offset: Int) -> Int {
                    digest[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                }
                let dependency = CodexUsageVec(input: word(0), cached: word(4),
                                               output: word(8), reasoning: word(12))
                let outcome = cache.resumable(for: path, baseline: dependency) { point in
                    Self.scan(path: path, origin: origin, resume: point,
                              baseline: dependency, replayIdentities: identities)
                }
                out += outcome.buckets
            } else { out += outcomes[path]?.buckets ?? [] }
        }
        return mergeBuckets(out)
    }

    private static func canonicalRoot(_ root: String) -> String {
        var ancestor = root
        var suffix: [String] = []
        while true {
            if let resolved = ancestor.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + suffix).joined(separator: "/")
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != ancestor else { return root }
            suffix.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = parent
        }
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
                     baseline: CodexUsageVec? = nil,
                     replayIdentities: Set<String>? = nil) -> ResumedBuckets? {
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
            if replayIdentities != nil { state.baselineUsed = baseline }
            else { state.applyBaseline(baseline) }
        }
        state.replaySourceIdentities = replayIdentities ?? []
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
                reduce(obj: obj, payload: payload, state: &state, origin: origin, acc: &acc, replayIdentities: replayIdentities ?? [])
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
                reduce(obj: obj, payload: payload, state: &tailState, origin: origin, acc: &tailAcc, replayIdentities: replayIdentities ?? [])
            }
            let tailBuckets = tailAcc.map { key, tokens in
                bucket(key, tokens)
            }
            let guardInfo = ScanCache.guardWindow(for: path, endingAt: result.resumeOffset)
            return ResumedBuckets(
                buckets: acc.map { bucket($0.key, $0.value) },
                tailBuckets: tailBuckets,
                position: ScanPosition(resumeOffset: result.resumeOffset,
                                       guardLength: guardInfo.length,
                                       guardHash: guardInfo.hash),
                state: state
            )
        }

        let guardInfo = ScanCache.guardWindow(for: path, endingAt: result.resumeOffset)
        return ResumedBuckets(
            buckets: acc.map { bucket($0.key, $0.value) },
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
                               acc: inout [BucketKey: TokenCounts],
                               replayIdentities: Set<String> = []) {
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
            applyMetadata(payload, state: &state)
            return

        case "turn_context":
            // A modern-only response in the previous turn cannot be the mirror
            // of a new turn's legacy response, even if their usage is identical.
            state.pendingModernUsage = nil
            state.pendingModernTimestamp = nil
            state.pendingModernResponseID = nil
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            state.serviceTier = nil
            state.speed = nil
            applyMetadata(payload, state: &state)
            return

        default:
            break
        }

        let info: [String: Any]
        let delta: CodexUsageVec
        if obj["type"] as? String == "token_usage_record" {
            // Modern Codex writes per-response usage before (and sometimes
            // without) its legacy token_count mirror. Its cumulative can differ
            // from the legacy one across migration/resume, so use response IDs.
            // Copied ancestor records retain their original thread identity.
            info = payload
            guard let usage = usageVec(payload["usage"]), usage.total > 0,
                  let responseID = payload["response_id"] as? String,
                  !responseID.isEmpty else { return }
            guard state.modernResponseIDs.insert(responseID).inserted else { return }
            let identity = "response:" + responseID
            state.replayIdentities.insert(identity)
            state.pendingModernUsage = usage
            state.pendingModernTimestamp = eventTime(obj)
            state.pendingModernResponseID = responseID
            if state.legacyResponseIDs.contains(responseID) { return }
            if replayIdentities.contains(identity) { return }
            if let thread = payload["thread_id"] as? String,
               !state.sessionId.isEmpty, thread != state.sessionId { return }
            delta = usage.clamped()
        } else {
            guard payload["type"] as? String == "token_count",
                  let legacy = payload["info"] as? [String: Any] else { return }
            info = legacy
            var total = usageVec(info["total_token_usage"])
            let last = usageVec(info["last_token_usage"])
            if total == nil, let l = last, l.total > 0 {
                total = state.peak + l
            }
            guard let t = total else { return }
            let response = (payload["response_id"] as? String) ?? (info["response_id"] as? String)
            if let response, !response.isEmpty { state.replayIdentities.insert("response:" + response) }
            if let response, !response.isEmpty,
               !state.legacyResponseIDs.insert(response).inserted { return }
            let identity = legacyIdentity(obj: obj, total: usageVec(info["total_token_usage"]), last: last)
            if let identity, !state.replayIdentities.insert(identity).inserted { return }
            // Always advance legacy state, including mirrored events: the next
            // legacy-only response must still see the correct reset/peak.
            let legacyDelta = CodexLineage.advance(&state, total: t, last: last)
            if let response, state.modernResponseIDs.contains(response) { return }
            if let response, replayIdentities.contains("response:" + response) { return }
            let correlated: Bool
            if let response {
                correlated = response == state.pendingModernResponseID
            } else if let now = eventTime(obj), let then = state.pendingModernTimestamp {
                correlated = now >= then && now - then <= 2
            } else { correlated = false }
            if let pending = state.pendingModernUsage, last == pending, correlated {
                state.pendingModernUsage = nil
                return
            }
            if let last, last.total > 0 { state.pendingModernUsage = nil }
            if let identity, replayIdentities.contains(identity) { return }
            guard let d = legacyDelta else { return }
            delta = d
        }

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
                            isSidechain: false,
                            provider: metadataString([payload, info], ["model_provider", "provider"]) ?? state.provider,
                            pricingTier: metadataString([payload, info], ["pricing_tier", "pricingTier"]) ?? state.pricingTier,
                            serviceTier: metadataString([payload, info, payload["usage"] as? [String: Any] ?? [:]], ["service_tier", "serviceTier"]) ?? state.serviceTier,
                            speed: metadataString([payload, info], ["speed"]) ?? state.speed,
                            inferenceGeo: metadataString([payload, info], ["inference_geo", "inferenceGeo"]) ?? state.inferenceGeo)
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

    private static func eventTime(_ obj: [String: Any]) -> Double? {
        guard let timestamp = obj["timestamp"] as? String else { return nil }
        return ISO8601Parser.date(from: timestamp)?.timeIntervalSince1970
    }

    private static func metadataString(_ sources: [[String: Any]], _ keys: [String]) -> String? {
        for source in sources {
            for key in keys {
                if let value = source[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func applyMetadata(_ payload: [String: Any], state: inout CodexScanState) {
        state.provider = metadataString([payload], ["model_provider", "provider"]) ?? state.provider
        state.pricingTier = metadataString([payload], ["pricing_tier", "pricingTier"]) ?? state.pricingTier
        state.serviceTier = metadataString([payload], ["service_tier", "serviceTier"]) ?? state.serviceTier
        state.speed = metadataString([payload], ["speed"]) ?? state.speed
        state.inferenceGeo = metadataString([payload], ["inference_geo", "inferenceGeo"]) ?? state.inferenceGeo
    }

    private static func bucket(_ key: BucketKey, _ counts: TokenCounts) -> UsageBucket {
        UsageBucket(origin: key.origin, cli: .codex, model: key.model, day: key.day,
                    tokens: counts, isSidechain: key.isSidechain, provider: key.provider,
                    pricingTier: key.pricingTier, serviceTier: key.serviceTier,
                    speed: key.speed, inferenceGeo: key.inferenceGeo)
    }

    static func legacyIdentity(obj: [String: Any], total: CodexUsageVec?,
                               last: CodexUsageVec?) -> String? {
        guard let timestamp = obj["timestamp"] as? String, !timestamp.isEmpty else { return nil }
        func vec(_ v: CodexUsageVec) -> String { "\(v.input),\(v.cached),\(v.output),\(v.reasoning)" }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let info = payload["info"] as? [String: Any] ?? [:]
        let response = metadataString([payload, info], ["response_id"]) ?? ""
        return "legacy:" + timestamp + ":" + (total.map(vec) ?? "nil") + ":" + (last.map(vec) ?? "nil") + ":" + response
    }
}
