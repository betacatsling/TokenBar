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
    /// First `session_meta` consumed; ancestors' metas replayed by a fork must
    /// not overwrite the identity recorded from the file's own meta.
    var sawSessionMeta: Bool = false
    var sessionId: String = ""
    var forkedFromId: String? = nil
    var isSubagent: Bool = false

    // Lineage watermarks. `peak`/`peakTotal` are the high-water marks an event's
    // cumulative must beat to charge anything; `prevTotal` is the last accepted
    // cumulative for regression detection; `maxTotal` is the file's historical
    // maximum, exported to the collector so a fork can start its peak at the
    // parent's final value.
    var peak: CodexUsageVec = .zero
    var peakTotal: Int = 0
    var prevTotal: Int? = nil
    var maxTotal: CodexUsageVec = .zero

    /// Fork baseline the current result was computed against. Cache hits and
    /// resumes are only valid while the collector offers the same baseline.
    var baselineUsed: CodexUsageVec? = nil

    /// Prime the watermarks at a parent's historical maximum. Events at or
    /// below it are the replayed parent history and charge nothing.
    mutating func applyBaseline(_ baseline: CodexUsageVec?) {
        guard let baseline, baseline.total > 0 else { baselineUsed = nil; return }
        baselineUsed = baseline
        peak = baseline
        peakTotal = baseline.total
        maxTotal = baseline
    }
}

/// Usage attribution for Codex `token_count` events — the part that is easiest
/// to get wrong. Adapted from usageBar's `CodexLineage`, whose rules are all
/// backed by measured rollout behaviour:
///
/// 1. **Peak gate.** A snapshot whose cumulative does not exceed the lineage
///    peak charges nothing. Re-emitted `token_count` rows and fork-replayed
///    parent history (all at or below the parent's final cumulative) collapse
///    here without needing timestamp heuristics.
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
            let d = (l.total <= advance
                     ? l
                     : (t - state.peak).bounded(to: advance)).clamped()
            state.peakTotal = t.total
            state.peak = state.peak.componentMax(t)
            return d.total > 0 ? d : nil
        }

        // Rule 1: at or below the peak — a duplicate, replay or stale row.
        state.peak = state.peak.componentMax(t)
        return nil
    }
}
