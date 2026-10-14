import Foundation
import SwiftUI
import AppKit
import SQLite3

/// `--verify` diagnostics.
///
/// Runs the real collectors and prints a machine-readable summary so totals can
/// be diffed against an independent implementation (see `Scripts/verify.py`).
/// Also reports the naive-sum-vs-deduped comparison for Claude Code, which is
/// the single easiest number to get wrong.
enum Verify {
    static func run() {
        let cachePath = ProcessInfo.processInfo.environment["TOKENBAR_VERIFY_CACHE"]
            ?? NSTemporaryDirectory() + "tokenbar-verify-cache.json"
        let cache = ScanCache(url: URL(fileURLWithPath: cachePath))
        // Cold by default so the numbers are reproducible; `--warm` reuses the
        // previous run's cache to measure incremental rescan cost.
        if !CommandLine.arguments.contains("--warm") {
            cache.clear()
        }

        let includeSidechain = CommandLine.arguments.contains("--include-sidechain")

        print("== TokenBar verify ==")
        print("host: \(Host.current().localizedName ?? "unknown")")
        print("date: \(DayFormatter.today())")
        print("includeSidechain: \(includeSidechain)")

        var all: [UsageBucket] = []
        var known = Set<String>()
        for collector in [ClaudeCodeCollector() as Collector,
                          CodexCollector(),
                          DevinCollector(),
                          PiCollector(), GeminiCollector(), OpenCodeCollector(), MagpieCollector()] {
            let start = Date()
            let collected = collector.collect(cache: cache)
            let elapsed = Date().timeIntervalSince(start)
            // Apply the sidechain filter here, not only at the merge below: the
            // per-collector line and the `cli.*` lines must describe the same set,
            // otherwise the printed parts do not sum to the printed total.
            let buckets = includeSidechain ? collected : collected.filter { !$0.isSidechain }
            let total = buckets.reduce(0) { $0 + $1.tokens.total }
            // String interpolation, not `%d`: these totals exceed 2^31 and the
            // C format specifier truncates them to 32 bits (negative output).
            let name = collector.cli.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            let files = "\(collector.discoverPaths().count)".padding(toLength: 6, withPad: " ", startingAt: 0)
            let tokenStr = "\(total)".padding(toLength: 14, withPad: " ", startingAt: 0)
            print("\(name) files=\(files) tokens=\(tokenStr) \(String(format: "%.2fs", elapsed))")
            all += buckets
            known.formUnion(collector.discoverPaths())
        }
        // Persist so a subsequent `--warm` run can prove the cache is effective.
        cache.save(knownPaths: known)

        // Already sidechain-filtered above, so no second filter here.
        let merged = mergeBuckets(all)
        let total = merged.reduce(0) { $0 + $1.tokens.total }
        let pricing = Pricing.loadDefault()
        let cost = pricing.estimate(merged)

        print("----")
        print("total_tokens: \(total)")
        print("total_cost_usd: \(String(format: "%.4f", cost.usd))")
        print("unpriced_tokens: \(cost.unpricedTokens)")
        print("reported_cost_usd: \(String(format: "%.4f", cost.reportedUSD))")
        print("reported_cost_tokens: \(cost.reportedTokens)")
        print("missing_codex_logs: \(CoverageReport.inspect(cache: cache).missingCodexLogs)")
        print("buckets: \(merged.count)")

        // Per-CLI breakdown, sorted for stable diffing.
        let byCLI = Dictionary(grouping: merged, by: { $0.cli.rawValue })
            .mapValues { $0.reduce(0) { $0 + $1.tokens.total } }
        for key in byCLI.keys.sorted() {
            print("cli.\(key): \(byCLI[key] ?? 0)")
        }

        // Per-day totals for the last 14 days.
        var byDay: [String: Int] = [:]
        for b in merged { byDay[b.day, default: 0] += b.tokens.total }
        for day in DayFormatter.recentDays(14) {
            print("day.\(day): \(byDay[day] ?? 0)")
        }

        // Per-model totals, printed only on request: model attribution is
        // invisible in the per-cli and per-day lines, so a mis-attribution (the
        // whole point of reading Devin's `generation_model`) would not show up in
        // a diff against the Python reference without these.
        if CommandLine.arguments.contains("--models") {
            print("----")
            var byModel: [String: Int] = [:]
            for b in merged { byModel[b.model, default: 0] += b.tokens.total }
            for model in byModel.keys.sorted() {
                print("model.\(model): \(byModel[model] ?? 0)")
            }
        }

        // Guard the dedup rule: summed-without-dedup must exceed the deduped value.
        reportClaudeDedupe()
        reportPiDedupe()
    }

    /// Compares deduped vs naive-sum totals for Claude Code to confirm the
    /// streaming-snapshot handling is actually taking effect.
    private static func reportClaudeDedupe() {
        var naive = 0
        var deduped = 0

        for path in ClaudeCodeCollector().discoverPaths() {
            var best: [String: TokenCounts] = [:]
            LineReader.forEachLine(path: path) { line in
                guard line.containsBytes(Needles.usage) else { return }
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }
                let counts = TokenCounts(
                    input: intValue(usage["input_tokens"]),
                    output: intValue(usage["output_tokens"]),
                    cacheRead: intValue(usage["cache_read_input_tokens"]),
                    cacheWrite: intValue(usage["cache_creation_input_tokens"])
                )
                guard counts.total > 0 else { return }
                guard (message["model"] as? String) != "<synthetic>" else { return }
                naive += counts.total

                let key: String
                if let mid = message["id"] as? String {
                    if let rid = obj["requestId"] as? String, !rid.isEmpty {
                        key = "\(mid):\(rid)"
                    } else {
                        key = "message:\(mid)"
                    }
                } else {
                    key = "uuid:\(obj["uuid"] as? String ?? "")"
                }
                best[key] = best[key]?.maxed(with: counts) ?? counts
            }
            deduped += best.values.reduce(0) { $0 + $1.total }
        }

        print("----")
        print("claude_naive_sum: \(naive)")
        print("claude_deduped: \(deduped)")
        if deduped > 0 {
            let ratio = Double(naive) / Double(deduped)
            print(String(format: "claude_naive_over_deduped_ratio: %.3f", ratio))
        }
    }

    /// Compares deduped vs naive-sum totals for pi to confirm the cross-file
    /// `responseId` deduplication is taking effect.
    private static func reportPiDedupe() {
        var naive = 0
        var seen = Set<String>()
        var deduped = 0

        for path in PiCollector().discoverPaths().sorted() {
            for ev in PiCollector.scanEvents(path: path) {
                naive += ev.tokens.total
                guard seen.insert(ev.rid).inserted else { continue }
                deduped += ev.tokens.total
            }
        }

        print("----")
        print("pi_naive_sum: \(naive)")
        print("pi_deduped: \(deduped)")
        if deduped > 0 {
            let ratio = Double(naive) / Double(deduped)
            print(String(format: "pi_naive_over_deduped_ratio: %.3f", ratio))
        }
    }

    /// Regression test for incremental resume.
    ///
    /// Codex rollouts are appended to while the app runs, so a refresh re-parses
    /// only the bytes added since the last scan. That shortcut is only safe if a
    /// resumed parse produces exactly what a full re-parse would, including when
    /// the writer leaves a half-written final line behind — the case most likely
    /// to double count. Each scenario below is checked against a from-scratch
    /// parse of the same bytes.
    static func testResume() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenbar-resume-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rollout.jsonl").path

        // Minimal rollout lines in Codex's on-disk shape.
        func meta(_ id: String) -> String {
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-01T00:00:00.000Z\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\"}}"
        }
        func turn(_ model: String) -> String {
            "{\"type\":\"turn_context\",\"timestamp\":\"2026-09-01T00:00:01.000Z\",\"payload\":{\"model\":\"\(model)\"}}"
        }
        func modern(_ response: String, total: Int = 100) -> String {
            "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-09-01T00:00:05Z\",\"payload\":{" +
            "\"thread_id\":\"modern\",\"response_id\":\"\(response)\"," +
            "\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":40,\"output_tokens\":10}," +
            "\"thread_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":10}}}"
        }
        /// `last` is this turn's delta; `total` is the running cumulative.
        /// `input` is inclusive of `cached`, matching Codex.
        func usage(last li: Int, _ lo: Int, cached lc: Int = 0,
                   total ti: Int, _ to: Int, tcached: Int = 0, at seconds: Int) -> String {
            let ts = String(format: "2026-09-01T00:%02d:%02d.000Z", seconds / 60, seconds % 60)
            return "{\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"token_count\",\"info\":{" +
                "\"last_token_usage\":{\"input_tokens\":\(li),\"cached_input_tokens\":\(lc),\"cache_write_input_tokens\":0,\"output_tokens\":\(lo),\"reasoning_output_tokens\":0}," +
                "\"total_token_usage\":{\"input_tokens\":\(ti),\"cached_input_tokens\":\(tcached),\"cache_write_input_tokens\":0,\"output_tokens\":\(to),\"reasoning_output_tokens\":0}}}}"
        }

        func write(_ text: String) {
            try? text.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
        func append(_ text: String) {
            guard let h = FileHandle(forWritingAtPath: path) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            h.write(Data(text.utf8))
        }
        /// Parse the whole file from byte 0, ignoring any cache.
        func fullParse() -> Int {
            let r = CodexCollector.scan(path: path, origin: .local,
                                        resume: ResumePoint(startOffset: 0, state: nil))
            let all = (r?.buckets ?? []) + (r?.tailBuckets ?? [])
            return all.reduce(0) { $0 + $1.tokens.total }
        }

        var failures: [String] = []
        func check(_ label: String, _ got: Int, _ want: Int) {
            let ok = got == want
            if !ok { failures.append(label) }
            print("resume: \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) got=\(got) want=\(want)  \(ok ? "ok" : "FAIL")")
        }

        // 1. Plain append. The resumed total must match a full re-parse, and the
        //    second scan must genuinely start where the first stopped.
        let cache = ScanCache(url: dir.appendingPathComponent("cache.json"))
        write([meta("s1"), turn("gpt-5.5"), usage(last: 100, 10, total: 100, 10, at: 5)]
            .joined(separator: "\n") + "\n")
        let first = cache.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("first scan", first, 110)

        append(usage(last: 200, 20, total: 300, 30, at: 10) + "\n")
        var resumedFrom: UInt64 = 0
        let second = cache.resumable(for: path) { p in
            resumedFrom = p.startOffset
            return CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("after append", second, fullParse())
        print("resume: resumed from byte offset       \(resumedFrom)  \(resumedFrom > 0 ? "ok" : "FAIL (re-parsed from 0)")")
        if resumedFrom == 0 { failures.append("did not resume") }

        // 2. The model is carried in reducer state, not re-read. An appended
        //    usage event with no new turn_context must still attribute to the
        //    model named before the resume point.
        let models = cache.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.map(\.model)
        let attributed = !models.isEmpty && models.allSatisfy { $0 == "gpt-5.5" }
        if !attributed { failures.append("model not carried across resume") }
        print("resume: model carried across resume    \(models)  \(attributed ? "ok" : "FAIL")")

        // 3. A half-written final line. It must be counted now (so the panel is
        //    current) and must not be counted twice once its newline arrives.
        let dir2 = dir.appendingPathComponent("t2")
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let cache2 = ScanCache(url: dir2.appendingPathComponent("cache.json"))
        write([meta("s2"), turn("gpt-5.5"), usage(last: 100, 10, total: 100, 10, at: 5)]
            .joined(separator: "\n") + "\n")
        _ = cache2.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }
        // Writer is mid-line: content, no trailing newline.
        append(usage(last: 500, 50, total: 600, 60, at: 20))
        let withPartial = cache2.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("partial line counted", withPartial, 660)

        // Writer finishes the line.
        append("\n")
        let completed = cache2.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("partial line not double counted", completed, 660)
        check("completed equals full re-parse", completed, fullParse())

        // 4. A rewritten file must invalidate the resume point rather than being
        //    parsed from a stale offset.
        let dir3 = dir.appendingPathComponent("t3")
        try? FileManager.default.createDirectory(at: dir3, withIntermediateDirectories: true)
        let cache3 = ScanCache(url: dir3.appendingPathComponent("cache.json"))
        write([meta("s3"), turn("gpt-5.5"), usage(last: 100, 10, total: 100, 10, at: 5)]
            .joined(separator: "\n") + "\n")
        _ = cache3.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }
        // Same growth direction, different content: a resume that ignored the
        // guard would keep the old 110 and add only the tail.
        write([meta("s3"), turn("gpt-5.5"),
               usage(last: 7, 3, total: 7, 3, at: 5),
               usage(last: 400, 40, total: 407, 43, at: 9)]
            .joined(separator: "\n") + "\n")
        let rewritten = cache3.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("rewritten file re-parsed", rewritten, 450)

        // 5. Re-emitted snapshots (same cumulative) are dropped, and cached
        //    input is not counted on top of input.
        let dir4 = dir.appendingPathComponent("t4")
        try? FileManager.default.createDirectory(at: dir4, withIntermediateDirectories: true)
        let cache4 = ScanCache(url: dir4.appendingPathComponent("cache.json"))
        write([meta("s4"), turn("gpt-5.5"),
               usage(last: 1000, 100, cached: 400, total: 1000, 100, tcached: 400, at: 5),
               usage(last: 1000, 100, cached: 400, total: 1000, 100, tcached: 400, at: 6)]
            .joined(separator: "\n") + "\n")
        let deduped = cache4.resumable(for: path) { p in
            CodexCollector.scan(path: path, origin: .local, resume: p)
        }.buckets.reduce(0) { $0 + $1.tokens.total }
        check("duplicate dropped, cache not added", deduped, 1100)

        // 6. Lineage rules, parsed from scratch with no cache involved.
        //    An inflated `last` (pre-0.142 Codex shape) must clamp to the
        //    cumulative diff, not charge what it claims.
        write([meta("s5"), turn("gpt-5.5"),
               usage(last: 200, 20, total: 150, 15, at: 5),
               usage(last: 100, 10, total: 250, 25, at: 10)]
            .joined(separator: "\n") + "\n")
        check("inflated last clamps to cumulative", fullParse(), 275)

        //    A cumulative drop equal to the new `last` is a counter restart
        //    (resume/compaction): watermarks reset and the fresh value counts.
        write([meta("s6"), turn("gpt-5.5"),
               usage(last: 100, 10, total: 100, 10, at: 5),
               usage(last: 50, 5, total: 150, 15, at: 10),
               usage(last: 60, 6, total: 60, 6, at: 15)]
            .joined(separator: "\n") + "\n")
        check("counter restart counts fresh", fullParse(), 231)

        //    Any other regression is a stale or out-of-order write: skipped
        //    without disturbing state, so the next genuine event still counts.
        write([meta("s7"), turn("gpt-5.5"),
               usage(last: 100, 10, total: 100, 10, at: 5),
               usage(last: 50, 5, total: 150, 15, at: 10),
               usage(last: 40, 4, total: 80, 8, at: 15),
               usage(last: 30, 3, total: 180, 18, at: 20)]
            .joined(separator: "\n") + "\n")
        check("stale regression skipped", fullParse(), 198)

        //    An inherited snapshot (`last` zero, positive cumulative) lifts
        //    the watermarks only — replayed forks write exactly this shape.
        write([meta("s8"), turn("gpt-5.5"),
               usage(last: 0, 0, total: 500, 50, at: 5),
               usage(last: 60, 6, total: 560, 56, at: 10)]
            .joined(separator: "\n") + "\n")
        check("inherited snapshot not charged", fullParse(), 66)

        // 7. An explicitly known snapshot boundary may prime the reducer.
        //    Collection uses replay identities, never a parent's later maximum.
        //    Each event's `last` equals its cumulative advance, as in real
        //    rollouts (advance > last only marks inherited bumps).
        write([meta("s9"), turn("gpt-5.5"),
               usage(last: 100, 10, total: 100, 10, at: 5),
               usage(last: 400, 40, total: 500, 50, at: 10),
               usage(last: 60, 6, total: 560, 56, at: 15)]
            .joined(separator: "\n") + "\n")
        let baseline = CodexUsageVec(input: 500, cached: 0, output: 50, reasoning: 0)
        let forked = CodexCollector.scan(path: path, origin: .local,
                                         resume: ResumePoint(startOffset: 0, state: nil),
                                         baseline: baseline)
        let forkTotal = (forked?.buckets ?? []).reduce(0) { $0 + $1.tokens.total }
        check("fork baseline skips replay", forkTotal, 66)
        //    Without the baseline the same file counts everything.
        check("same file unbaselined", fullParse(), 616)

        // Modern-only usage must be visible immediately; a later legacy mirror
        // may use a DIFFERENT cumulative offset (observed on migrated logs).
        let modernCacheURL = dir.appendingPathComponent("modern-cache.json")
        var modernCache = ScanCache(url: modernCacheURL)
        write([meta("modern"), turn("gpt-6-luna"), modern("response-1")]
            .joined(separator: "\n") + "\n")
        func modernScan() -> [UsageBucket] {
            modernCache.resumable(for: path) { p in
                CodexCollector.scan(path: path, origin: .local, resume: p)
            }.buckets
        }
        check("modern-only luna response", modernScan().reduce(0) { $0 + $1.tokens.total }, 110)
        modernCache.save(knownPaths: [path])
        modernCache = ScanCache(url: modernCacheURL)
        append(usage(last: 100, 10, cached: 40, total: 5100, 510, tcached: 2040, at: 6) + "\n")
        check("persisted mirror different offset", modernScan().reduce(0) { $0 + $1.tokens.total }, 110)
        append(modern("response-1") + "\n")
        check("persisted response ID dedup", modernScan().reduce(0) { $0 + $1.tokens.total }, 110)
        // The same usage under another response ID is a distinct paid call.
        // Parse an unterminated tail, then finish it: neither scan may lose or
        // double count it, and the tail must not persist the response ID early.
        append(modern("response-2", total: 200))
        check("modern tail visible", modernScan().reduce(0) { $0 + $1.tokens.total }, 220)
        append("\n" + usage(last: 100, 10, cached: 40, total: 100, 10, tcached: 40, at: 7) + "\n")
        let modernBuckets = modernScan()
        check("modern tail and legacy reset", modernBuckets.reduce(0) { $0 + $1.tokens.total }, 220)
        check("modern cold equals resumed", fullParse(), 220)
        check("modern cached subset", modernBuckets.reduce(0) { $0 + $1.tokens.cacheRead }, 80)
        check("modern model retained", modernBuckets.allSatisfy { $0.model == "gpt-6-luna" } ? 1 : 0, 1)

        // Audit: clamp negative component differences BEFORE the scalar cap.
        write([meta("regression"), turn("gpt-6-luna"),
               usage(last: 1000, 0, total: 1000, 0, at: 5),
               usage(last: 200, 0, total: 100, 1000, at: 10)].joined(separator: "\n") + "\n")
        check("component regression scalar cap", fullParse(), 1100)
        let resetHistory = [usage(last: 1000, 0, total: 1000, 0, at: 5),
                            usage(last: 100, 0, total: 100, 0, at: 10),
                            usage(last: 100, 0, total: 200, 0, at: 15)]
        write(([meta("replay"), turn("gpt-6-luna")] + resetHistory + resetHistory +
               [usage(last: 100, 0, total: 300, 0, at: 20)]).joined(separator: "\n") + "\n")
        check("replayed resets not rebilled", fullParse(), 1300)
        write([meta("modern"), turn("gpt-6-luna"), modern("separate"),
               usage(last: 100, 10, cached: 40, total: 100, 10, at: 30)].joined(separator: "\n") + "\n")
        check("equal independent modern and legacy", fullParse(), 220)
        let providerMeta = meta("modern").replacingOccurrences(of: "\"source\":\"vscode\"",
            with: "\"source\":\"vscode\",\"model_provider\":\"custom-gateway\"")
        let priority = modern("priority").replacingOccurrences(of: "\"response_id\":\"priority\"",
            with: "\"response_id\":\"priority\",\"service_tier\":\"priority\"")
        write([providerMeta, turn("gpt-6-luna"), priority].joined(separator: "\n") + "\n")
        let metadataBuckets = CodexCollector.scan(path: path, origin: .local,
            resume: ResumePoint(startOffset: 0, state: nil))?.buckets ?? []
        check("Codex provider and priority preserved", metadataBuckets.contains {
            $0.provider == "custom-gateway" && $0.serviceTier == "priority"
        } ? 1 : 0, 1)

        print("----")
        print("resume: RESULT = \(failures.isEmpty ? "PASS" : "FAIL (\(failures.joined(separator: ", ")))")")
        if !failures.isEmpty { exit(1) }
    }

    /// Regression test for the WAL sidecar cache key.
    ///
    /// A WAL-mode SQLite database commits new rows into `-wal`, leaving the main
    /// `.db` file's size and mtime untouched until a checkpoint. Keying freshness
    /// on the `.db` alone therefore serves stale results; this test builds exactly
    /// that situation in a temp database and checks the cache notices. It fails if
    /// the sidecar signature is removed from `ScanCache.buckets(for:sidecars:)`.
    static func testWALSidecarInvalidation() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenbar-waltest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("sessions.db").path

        // Hold one connection open for the whole test. SQLite checkpoints the WAL
        // into the main file when the *last* connection closes, which would fold
        // the new rows in and mask the very effect under test.
        var holder: OpaquePointer?
        guard sqlite3_open(dbPath, &holder) == SQLITE_OK, let holder else {
            print("walcache: could not open test db")
            return
        }
        defer { sqlite3_close(holder) }
        sqlite3_exec(holder, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(holder, "CREATE TABLE metrics(amount INTEGER);", nil, nil, nil)
        sqlite3_exec(holder, "INSERT INTO metrics VALUES (10),(20),(30);", nil, nil, nil)
        // Fold the baseline into the main file and empty the WAL, so the second
        // write is unambiguously WAL-only.
        sqlite3_exec(holder, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)

        func stat(_ path: String) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
            let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(String(format: "%.6f", mtime))"
        }

        func sum(_ path: String) -> Int {
            var db: OpaquePointer?
            guard sqlite3_open_v2("file:\(path)?mode=ro", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                  let db else { return -1 }
            defer { sqlite3_close(db) }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(amount),0) FROM metrics",
                                     -1, &st, nil) == SQLITE_OK, let st else { return -1 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : -1
        }

        let cache = ScanCache(url: dir.appendingPathComponent("cache.json"))
        let sidecars = DevinCollector.sidecarPaths(for: dbPath)
        func scanThroughCache() -> Int {
            let buckets = cache.buckets(for: dbPath, sidecars: sidecars) { _ in
                [UsageBucket(origin: .local, cli: .devin, model: "t", day: DayFormatter.today(),
                             tokens: TokenCounts(input: sum(dbPath), output: 0,
                                                 cacheRead: 0, cacheWrite: 0),
                             isSidechain: false)]
            }
            return buckets.first?.tokens.input ?? -1
        }

        let before = stat(dbPath)
        let first = scanThroughCache()

        // Write through a second connection while `holder` stays open, so these
        // rows exist only in the WAL.
        var writer: OpaquePointer?
        if sqlite3_open(dbPath, &writer) == SQLITE_OK, let writer {
            sqlite3_exec(writer, "INSERT INTO metrics VALUES (40),(50);", nil, nil, nil)
            sqlite3_close(writer)
        }
        let after = stat(dbPath)
        let second = scanThroughCache()

        // The main file must be untouched, otherwise the test proves nothing —
        // a plain size/mtime key would have caught the change too.
        let dbFrozen = before == after
        let invalidated = second != first
        let correct = (first == 60 && second == 150)

        print("----")
        print("walcache: main-file stat before = \(before)")
        print("walcache: main-file stat after  = \(after)")
        print("walcache: db-file frozen        = \(dbFrozen)")
        print("walcache: first scan            = \(first)  (expect 60)")
        print("walcache: second scan           = \(second)  (expect 150)")
        print("walcache: invalidated on WAL write = \(invalidated)")
        print("walcache: RESULT = \(dbFrozen && invalidated && correct ? "PASS" : "FAIL")")
    }

    /// Render the popover to a PNG for visual inspection.    ///
    /// Runs the real view against the real data in an offscreen window, so a
    /// broken layout or an empty list shows up here rather than only when a
    /// human clicks the menu bar icon.
    @MainActor
    static func render(path: String) {
        let settings = Settings.scratch()
        if CommandLine.arguments.contains("--no-remote") { settings.remoteEnabled = false }
        // Allow the host to be overridden so the unreachable-server path can be
        // exercised deliberately.
        if let index = CommandLine.arguments.firstIndex(of: "--host"),
           CommandLine.arguments.count > index + 1 {
            settings.remoteHost = CommandLine.arguments[index + 1]
        }
        // `autoScan: false` — this harness scans synchronously right after, and
        // letting the init-launched detached scan race it corrupted the shared
        // ScanCache (SIGSEGV in Dictionary.subscript.getter).
        let model = AppModel(settings: settings, autoScan: false)
        model.scanBlocking(includeRemote: !CommandLine.arguments.contains("--no-remote"))

        // Match whichever range the user asked for, if any.
        if let index = CommandLine.arguments.firstIndex(of: "--range"),
           CommandLine.arguments.count > index + 1,
           let range = TimeRange(rawValue: CommandLine.arguments[index + 1]) {
            model.setRange(range)
        }

        var initialTab: BreakdownTab = .cli
        if let index = CommandLine.arguments.firstIndex(of: "--tab"),
           CommandLine.arguments.count > index + 1,
           let t = BreakdownTab(rawValue: CommandLine.arguments[index + 1]) {
            initialTab = t
        }
        // `--expand codex` opens that CLI's model detail on the 按 CLI tab.
        var initialExpanded: CLIKind?
        if let index = CommandLine.arguments.firstIndex(of: "--expand"),
           CommandLine.arguments.count > index + 1 {
            initialExpanded = CLIKind(rawValue: CommandLine.arguments[index + 1])
        }

        // `--settings` renders the gear's popover instead of the panel.
        let content = CommandLine.arguments.contains("--settings")
            ? AnyView(SettingsView(settings: settings, model: model))
            : AnyView(PopoverView(model: model, initialTab: initialTab, initialExpanded: initialExpanded)
                .frame(width: Theme.panelWidth))

        // `--dark` checks the dark steps of the palette without flipping the
        // whole system's appearance.
        let dark = CommandLine.arguments.contains("--dark")
        let view = content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)

        let controller = NSHostingController(rootView: view)
        controller.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = controller.view.fittingSize
        controller.view.frame = NSRect(origin: .zero, size: size)

        guard let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
            FileHandle.standardError.write(Data("render: could not allocate bitmap\n".utf8))
            return
        }
        controller.view.cacheDisplay(in: controller.view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render: PNG encoding failed\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("rendered: \(path) (\(Int(size.width))x\(Int(size.height)))")
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
        }
    }
}
