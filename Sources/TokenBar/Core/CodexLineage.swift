import Foundation

/// The four cumulative counters Codex reports per `token_count` event.
///
/// `cached` is a subset of `input` and `reasoning` a subset of `output`, so the
/// session-cumulative scalar is `input + output` — never the field sum. Verified
/// against Codex's own `total_tokens` on this machine's rollouts.
struct CodexUsageVec: Codable, Hashable {
    /// Includes `cached`.
    var input: Int = 0
    /// Subset of `input` served from the prompt cache.
    var cached: Int = 0
    /// Includes `reasoning`.
    var output: Int = 0
    /// Subset of `output` spent on reasoning.
    var reasoning: Int = 0

    static let zero = CodexUsageVec()

    /// Cumulative scalar: input + output. The subsets must not be added again.
    var total: Int { input + output }

    func componentMax(_ o: CodexUsageVec) -> CodexUsageVec {
        CodexUsageVec(input: max(input, o.input), cached: max(cached, o.cached),
                      output: max(output, o.output), reasoning: max(reasoning, o.reasoning))
    }

    static func + (a: CodexUsageVec, b: CodexUsageVec) -> CodexUsageVec {
        CodexUsageVec(input: a.input + b.input, cached: a.cached + b.cached,
                      output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }

    static func - (a: CodexUsageVec, b: CodexUsageVec) -> CodexUsageVec {
        CodexUsageVec(input: a.input - b.input, cached: a.cached - b.cached,
                      output: a.output - b.output, reasoning: a.reasoning - b.reasoning)
    }

    /// Clamp negative components to 0 and subsets to their parents. Deltas taken
    /// against a per-component peak can regress on a single component, and a
    /// malformed row can claim more cached than input.
    func clamped() -> CodexUsageVec {
        let i = max(0, input), o = max(0, output)
        return CodexUsageVec(input: i, cached: min(max(0, cached), i),
                             output: o, reasoning: min(max(0, reasoning), o))
    }

    /// Bound `total` to `cap` by trimming the billable components. A fallback
    /// diff `total - peak` can claim more than the scalar advance when one
    /// component regressed while another advanced; the cumulative scalar is
    /// the honest bound, so excess is cut from input first (the largest,
    /// least precise bucket) then output.
    func bounded(to cap: Int) -> CodexUsageVec {
        if self != clamped() { return clamped().bounded(to: max(0, cap)) }
        guard total > cap else { return self }
        var d = self
        var excess = total - cap
        let i = min(excess, d.input)
        d.input -= i
        d.cached = min(d.cached, d.input)
        excess -= i
        if excess > 0 {
            let o = min(excess, d.output)
            d.output -= o
            d.reasoning = min(d.reasoning, d.output)
        }
        return d
    }
}

/// Rolling state carried across lines — and across resumable scans — of one
/// Codex rollout. Persisted inside `CachedFileScan`, so every field must stay
/// meaningful when the file keeps being appended to.
struct CodexScanState: Codable, Hashable {
    /// Active model, carried forward from the most recent `turn_context`.
    var model: String = ""
    var provider: String? = nil
    var pricingTier: String? = nil
    var serviceTier: String? = nil
    var speed: String? = nil
    var inferenceGeo: String? = nil
    /// First `session_meta` consumed; ancestors' metas replayed by a fork must
    /// not overwrite the identity recorded from the file's own meta.
    var sawSessionMeta: Bool = false
    var sessionId: String = ""
    var forkedFromId: String? = nil
    var isSubagent: Bool = false

    /// Modern records identify individual responses. Their thread counter can
    /// start at a different offset from token_count and must not share its peak.
    var modernResponseIDs: Set<String> = []
    var legacyResponseIDs: Set<String> = []
    var pendingModernUsage: CodexUsageVec? = nil
    var pendingModernTimestamp: Double? = nil
    var pendingModernResponseID: String? = nil
    /// Stable event identities, including inherited history. Persisted so a
    /// missing parent's retained scan still identifies copied resets.
    var replayIdentities: Set<String> = []
    var replaySourceIdentities: Set<String> = []

    // Lineage watermarks. `peak`/`peakTotal` are the high-water marks an event's
    // cumulative must beat to charge anything; `prevTotal` is the last accepted
    // cumulative for regression detection; `maxTotal` is the file's historical
    // maximum, retained for diagnostics. It is not a fork boundary.
    var peak: CodexUsageVec = .zero
    var peakTotal: Int = 0
    var prevTotal: Int? = nil
    var maxTotal: CodexUsageVec = .zero

    /// Explicit boundary or opaque parent-identity dependency cache key.
    /// Identity-based scans never apply the dependency as a token watermark.
    var baselineUsed: CodexUsageVec? = nil

    /// Prime watermarks only at an explicitly known snapshot boundary.
    /// Never use the parent's final maximum as a inferred fork boundary.
    mutating func applyBaseline(_ baseline: CodexUsageVec?) {
        guard let baseline, baseline.total > 0 else { baselineUsed = nil; return }
        baselineUsed = baseline
        peak = baseline
        peakTotal = baseline.total
        maxTotal = baseline
    }

    enum CodingKeys: String, CodingKey {
        case model, provider, pricingTier, serviceTier, speed, inferenceGeo
        case sawSessionMeta, sessionId, forkedFromId, isSubagent, modernResponseIDs, legacyResponseIDs
        case pendingModernUsage, pendingModernTimestamp, pendingModernResponseID
        case replayIdentities, replaySourceIdentities, peak, peakTotal, prevTotal, maxTotal, baselineUsed
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        pricingTier = try c.decodeIfPresent(String.self, forKey: .pricingTier)
        serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
        speed = try c.decodeIfPresent(String.self, forKey: .speed)
        inferenceGeo = try c.decodeIfPresent(String.self, forKey: .inferenceGeo)
        sawSessionMeta = try c.decodeIfPresent(Bool.self, forKey: .sawSessionMeta) ?? false
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        forkedFromId = try c.decodeIfPresent(String.self, forKey: .forkedFromId)
        isSubagent = try c.decodeIfPresent(Bool.self, forKey: .isSubagent) ?? false
        modernResponseIDs = try c.decodeIfPresent(Set<String>.self, forKey: .modernResponseIDs) ?? []
        legacyResponseIDs = try c.decodeIfPresent(Set<String>.self, forKey: .legacyResponseIDs) ?? []
        pendingModernUsage = try c.decodeIfPresent(CodexUsageVec.self, forKey: .pendingModernUsage)
        pendingModernTimestamp = try c.decodeIfPresent(Double.self, forKey: .pendingModernTimestamp)
        pendingModernResponseID = try c.decodeIfPresent(String.self, forKey: .pendingModernResponseID)
        replayIdentities = try c.decodeIfPresent(Set<String>.self, forKey: .replayIdentities) ?? []
        replaySourceIdentities = try c.decodeIfPresent(Set<String>.self, forKey: .replaySourceIdentities) ?? []
        peak = try c.decodeIfPresent(CodexUsageVec.self, forKey: .peak) ?? .zero
        peakTotal = try c.decodeIfPresent(Int.self, forKey: .peakTotal) ?? 0
        prevTotal = try c.decodeIfPresent(Int.self, forKey: .prevTotal)
        maxTotal = try c.decodeIfPresent(CodexUsageVec.self, forKey: .maxTotal) ?? .zero
        baselineUsed = try c.decodeIfPresent(CodexUsageVec.self, forKey: .baselineUsed)
    }
}

/// Usage attribution for Codex `token_count` events — the part that is easiest
/// to get wrong. Adapted from usageBar's `CodexLineage`, whose rules are all
/// backed by measured rollout behaviour:
///
/// 1. **Peak gate.** A snapshot whose cumulative does not exceed the lineage
///    peak charges nothing. Re-emitted `token_count` rows and fork-replayed
///    history collapse here. Copied resets are filtered by persisted event
///    identities in the collector before they can restart the counter again.
/// 2. **`min(last, advance)`.** The honest increment is `last_token_usage` —
///    but only when it does not exceed the cumulative advance. Pre-0.142 Codex
///    inflated `last` by up to ~2x (measured: this machine's oldest rollouts
///    sum to 1.81B against 1.71B actual), in which case the cumulative diff
///    `total - peak` is used instead.
/// 3. **Inherited snapshots.** `last == 0` with a positive cumulative is a
///    baseline written by a fork/copy: it lifts the watermarks but is never
///    charged.
/// 4. **Counter restarts.** A cumulative that falls below the previous one is
///    a restart (resume/compaction) only when `last` equals the new cumulative;
///    then the watermarks reset and the fresh sequence counts normally.
/// 5. **Stale regressions.** Any other drop is an out-of-order or replayed
///    write — skipped without touching state, so it cannot become a phantom
///    "restart" that re-bills earlier turns.
enum CodexLineage {

    /// Fold one `token_count` snapshot into `state`. Returns the component
    /// delta to charge (clamped, `total > 0`), or nil when the event adds no
    /// new usage.
    static func advance(_ state: inout CodexScanState,
                        total t: CodexUsageVec,
                        last l: CodexUsageVec?) -> CodexUsageVec? {
        guard t.total > 0 else { return nil }
        state.maxTotal = state.maxTotal.componentMax(t)

        guard let l, l.total > 0 else {
            // Rule 3: watermark-only snapshot (also the shape of a summary row
            // with no `last` — treated conservatively, never charged raw).
            state.peak = state.peak.componentMax(t)
            state.peakTotal = max(state.peakTotal, t.total)
            state.prevTotal = t.total
            return nil
        }

        if let prev = state.prevTotal, t.total < prev {
            if l.total == t.total {
                // Rule 4: restarted counter. The new cumulative IS this turn's
                // usage, so reset watermarks and let the emit branch charge it.
                state.peak = .zero
                state.peakTotal = 0
            } else {
                // Rule 5: stale write.
                return nil
            }
        }
        state.prevTotal = t.total

        if t.total > state.peakTotal {
            let advance = t.total - state.peakTotal
            // Rule 2: `last` is trusted only as a bounded increment; when it
            // exceeds the cumulative advance (inflated writes) the component
            // diff is used instead, still capped by the scalar advance.
            let d = (l.total <= advance ? l : (t - state.peak))
                .clamped().bounded(to: advance)
            state.peakTotal = t.total
            state.peak = state.peak.componentMax(t)
            return d.total > 0 ? d : nil
        }

        // Rule 1: at or below the peak — a duplicate, replay or stale row.
        state.peak = state.peak.componentMax(t)
        return nil
    }
}
