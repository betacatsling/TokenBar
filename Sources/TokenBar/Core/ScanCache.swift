import Foundation

/// Streams a file line by line without loading it into memory.
///
/// Needed because the Codex log directory is 2.4 GB and individual rollout
/// files reach 577 MB. `String(contentsOfFile:)` on those would balloon RSS.
struct LineReader {
    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var eof = false

    init?(path: String, chunkSize: Int = 1 << 20) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
        self.chunkSize = chunkSize
    }

    /// Start reading at a byte offset (used to tail large files).
    init?(path: String, startingAt offset: UInt64, chunkSize: Int = 1 << 20) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
        self.chunkSize = chunkSize
        if offset > 0 {
            try? h.seek(toOffset: offset)
            // The offset likely lands mid-line; drop the partial remainder.
            _ = nextLine()
        }
    }

    mutating func nextLine() -> Data? {
        let newline = UInt8(ascii: "\n")
        while true {
            if let idx = buffer.firstIndex(of: newline) {
                let line = Data(buffer[buffer.startIndex..<idx])
                // Re-copy instead of keeping the slice: `Data(buffer[(idx+1)...])`
                // shares the original backing store, so appending more chunks
                // keeps that entire allocation alive. On the 604 MB rollouts here
                // that alone pushed peak RSS past 500 MB; re-copying bounds the
                // buffer by the chunk size instead of by the file size.
                buffer = Data(buffer[(idx + 1)...])
                return line
            }
            if eof {
                guard !buffer.isEmpty else { return nil }
                let rest = Data(buffer)
                buffer = Data()
                return rest
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
        }
    }

    func close() { try? handle.close() }

    /// Iterate every line, calling `body` for each. Closes the handle when done.
    static func forEachLine(path: String, startingAt offset: UInt64 = 0, _ body: (Data) -> Void) {
        guard var reader = LineReader(path: path, startingAt: offset) else { return }
        while let line = reader.nextLine() {
            if !line.isEmpty { body(line) }
        }
        reader.close()
    }

    /// Like `forEachLine`, but stops as soon as `body` returns false.
    ///
    /// Needed for peek-style reads: without an early exit, inspecting the first
    /// line of a 577 MB rollout reads the whole file.
    static func forEachLineWhile(path: String, startingAt offset: UInt64 = 0,
                                 _ body: (Data) -> Bool) {
        guard var reader = LineReader(path: path, startingAt: offset) else { return }
        while let line = reader.nextLine() {
            if line.isEmpty { continue }
            if !body(line) { break }
        }
        reader.close()
    }
}

// MARK: - Offset-tracking scan

/// Where a scan stopped, plus a fingerprint of the bytes just before it.
///
/// The guard exists because resuming assumes the file is append-only. A rotated,
/// truncated or rewritten file would otherwise be parsed from the middle and
/// produce silently wrong totals. Hashing the whole prefix would cost the full
/// re-read that resuming exists to avoid, so only a small window is fingerprinted
/// — enough to catch the realistic failure shapes, all of which disturb the bytes
/// adjacent to the resume point.
struct ScanPosition: Codable, Hashable {
    /// Byte offset just past the last newline-terminated line consumed.
    var resumeOffset: UInt64
    var guardLength: Int
    var guardHash: UInt32
}

/// Result of a scan that tracked byte offsets.
struct LineScanResult {
    /// Byte offset just past the last newline-terminated line consumed.
    var resumeOffset: UInt64
    /// Bytes after the final newline. Deliberately *not* counted as consumed: the
    /// writer may still be extending this line, and counting a half record now
    /// and its complete form on the next scan would double count it.
    var tail: Data?
}

enum FNV1a {
    static func hash(_ data: Data) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<raw.count {
                h ^= UInt32(base[i])
                h = h &* 0x01000193
            }
        }
        return h
    }
}

/// Line-at-a-time scan that reports the byte offset it stopped at.
///
/// Separate from `LineReader` because resuming incremental parses needs byte-exact
/// offsets, which a decoded `String` cannot provide. Used by collectors that keep a
/// resume position; the others keep using `LineReader`.
enum LineScanner {
    /// Scans newline-terminated lines from `start`, calling `body` for each.
    ///
    /// Returns nil when the file cannot be opened — the caller must distinguish
    /// that from "parsed successfully and found nothing", or a transient read
    /// failure would be memoised as a stable fact.
    @discardableResult
    static func scan(path: String, from start: UInt64, chunkSize: Int = 1 << 20,
                     _ body: (Data) -> Void) -> LineScanResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if start > 0 { try? handle.seek(toOffset: start) }

        let newline = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        var buffer = Data()
        // Index of the first unconsumed byte. Kept as an offset rather than
        // slicing per line: repeatedly re-copying the remaining buffer is
        // quadratic on a chunk holding many lines.
        var cursor = 0
        var resumeOffset = start
        var eof = false

        while true {
            let found: Int? = buffer.withUnsafeBytes { raw -> Int? in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                var i = cursor
                while i < raw.count {
                    if base[i] == newline { return i }
                    i += 1
                }
                return nil
            }

            if let index = found {
                var line = Data(buffer[cursor..<index])
                if line.last == carriageReturn { line.removeLast() }
                if !line.isEmpty { body(line) }
                resumeOffset += UInt64(index + 1 - cursor)
                cursor = index + 1
                // Compact only when the consumed prefix is worth reclaiming, so
                // the common case stays a pointer bump.
                if cursor == buffer.count {
                    buffer.removeAll(keepingCapacity: true)
                    cursor = 0
                } else if cursor >= (1 << 19) {
                    buffer = Data(buffer[cursor...])
                    cursor = 0
                }
                continue
            }

            if eof { break }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
        }

        return LineScanResult(resumeOffset: resumeOffset,
                              tail: cursor < buffer.count ? Data(buffer[cursor...]) : nil)
    }
}

// MARK: - Cheap pre-filter

extension Data {
    /// Substring search on raw bytes. Much cheaper than decoding a 500 KB JSON
    /// line to UTF-8 just to discover it has no usage field.
    func containsBytes(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = count - needle.count
            let first = needle[0]
            var i = 0
            while i <= limit {
                if base[i] == first {
                    var j = 1
                    while j < needle.count, base[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    /// True when any of `needles` occurs. One pass over the line instead of one
    /// per needle, which matters because this gates every line of a 2.7 GB tree.
    func containsAnyBytes(_ needles: [[UInt8]]) -> Bool {
        let usable = needles.filter { !$0.isEmpty && count >= $0.count }
        guard !usable.isEmpty else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            var i = 0
            while i < count {
                let byte = base[i]
                for needle in usable where needle[0] == byte && i + needle.count <= count {
                    var j = 1
                    while j < needle.count, base[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }
}

enum Needles {
    static let usage = Array("\"usage\"".utf8)
    static let tokenCount = Array("\"token_count\"".utf8)
    static let tokenUsageRecord = Array("\"token_usage_record\"".utf8)
    static let turnContext = Array("\"turn_context\"".utf8)
    static let sessionMeta = Array("\"session_meta\"".utf8)
    /// Every Codex line that can change the reducer's output.
    static let codexRelevant = [tokenCount, tokenUsageRecord, turnContext, sessionMeta]
}

// MARK: - Scan cache

/// Bump when a parser change means previously cached numbers are wrong.
///
/// v1 stored Codex usage as a tail-read cumulative total, which double counted
/// forked rollouts and lost everything before a mid-session counter reset. Those
/// entries must not survive: they would keep serving inflated totals forever,
/// because an unchanged file is never re-parsed.
///
/// v2 counted every Devin `message_nodes` row, but Devin re-materialises each
/// message once per following turn, so one API call was billed up to 7 times
/// (2.485× overall). v3 de-duplicates by `message_id` and re-attributes pi usage
/// to `responseModel`. v4 attributes Devin to `metadata.generation_model` rather
/// than `sessions.model`, which is the session's current setting and mislabels
/// every call made before a mid-session switch. v5 collapses `swe-2-high` /
/// `swe-2-max` into `swe-2` — effort tiers of one model, not two models. v6
/// buckets Devin usage by `metadata.created_at` (when the call happened) rather
/// than the row's `created_at` (when a later turn re-materialised that copy).
/// v7 rewrites Codex accounting around a cumulative lineage (peak gate +
/// `min(last, advance)` + restart/stale handling + fork baselines) instead of
/// summing raw `last_token_usage`, and dedups Claude/pi per-record across
/// files — copied transcripts used to bill every copy. v8 counts Codex
/// subagent-thread usage as normal usage: v7 marked it `isSidechain`, which
/// dropped real billed tokens whenever the sidechain filter was on.
/// v9 also reads modern `token_usage_record` rows and reconciles their legacy
/// mirrors without mixing the two formats' independent cumulative counters.
private let scanCacheVersion = 10

/// Per-file memo of a previous scan, keyed by identity + mtime + size.
struct CachedFileScan: Codable {
    var size: UInt64
    var mtime: Double
    var inode: UInt64
    /// Freshness of any auxiliary files whose writes do not touch the main file.
    /// Optional so caches written before this field existed still decode.
    var sidecarSignature: String?
    /// Buckets from newline-terminated lines.
    var buckets: [UsageBucket]
    /// Buckets from the unterminated trailing segment. Kept apart so a resumed
    /// parse — which re-reads that segment from `position.resumeOffset` — cannot
    /// count it twice.
    var tailBuckets: [UsageBucket]?
    /// Where the parse stopped, for resuming a file that has since grown.
    var position: ScanPosition?
    /// Reducer state as of `position`. Codex carries the active model forward
    /// across lines, so a resumed parse cannot start from a blank state.
    var codexState: CodexScanState?
    /// Per-record events for collectors that dedup across files (Claude, pi).
    /// Set instead of `buckets` for those collectors.
    var events: [UsageEventRecord]?
}

/// Everything a resumable scan returns.
struct ResumedBuckets {
    var buckets: [UsageBucket]
    var tailBuckets: [UsageBucket]
    var position: ScanPosition
    var state: CodexScanState?

    init(buckets: [UsageBucket], tailBuckets: [UsageBucket] = [],
         position: ScanPosition, state: CodexScanState? = nil) {
        self.buckets = buckets
        self.tailBuckets = tailBuckets
        self.position = position
        self.state = state
    }
}

/// Where a resumable scan should start, and the state carried into it.
struct ResumePoint {
    var startOffset: UInt64
    var state: CodexScanState?
}

/// What `resumable` hands back: the file's current totals plus the reducer
/// state the caller needs for cross-file bookkeeping (fork baselines).
struct ResumableOutcome {
    var buckets: [UsageBucket]
    var state: CodexScanState?
}

/// Incremental scan cache persisted to Application Support.
///
/// Rescanning 2.7 GB on every popover open would be wasteful, so each file's
/// aggregated result is memoized against `(inode, size, mtime)` plus any sidecar
/// signature. Any write to a session file changes size and mtime, so staleness is
/// not a concern — except for the WAL case below, where it is.
///
/// Thread safety: entries are guarded by `lock`. Scans normally run one at a time
/// (the model guards on `isScanning`), but `clearCache` is reachable from the UI
/// while a detached scan is in flight, and a plain Swift `Dictionary` mutated from
/// two threads corrupts its storage — observed here as an `EXC_BAD_ACCESS` inside
/// `Dictionary.subscript.getter`. The `compute` closure deliberately runs outside
/// the lock so a long scan never blocks a concurrent cache read.
final class ScanCache {
    private var entries: [String: CachedFileScan]
    private let url: URL
    private var dirty = false
    private let lock = NSLock()

    /// Fingerprinted window for `ScanPosition.guardHash`.
    static let guardLength = 64

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TokenBar/scan-cache.json")
    }

    /// Versioned on-disk envelope. The bare dictionary was replaced so a parser
    /// change can invalidate stored results instead of serving them forever.
    private struct Persisted: Codable {
        var version: Int
        var files: [String: CachedFileScan]
    }

    init(url: URL = ScanCache.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            entries = decoded.files
            // Reparse available logs after parser upgrades, but keep the only
            // surviving evidence for logs that have been removed.
            if decoded.version != scanCacheVersion {
                for path in entries.keys where FileManager.default.fileExists(atPath: path) {
                    entries[path]?.mtime = -1
                    entries[path]?.position = nil
                    entries[path]?.codexState = nil
                }
                dirty = true
            }
        } else {
            entries = [:]
        }
    }

    /// History already observed under this configured root. A deleted log must
    /// not silently erase consumption; collectors still deduplicate these rows.
    func retainedPaths(under root: String) -> [String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        lock.lock(); defer { lock.unlock() }
        return entries.keys.filter { $0 == root || $0.hasPrefix(prefix) }.sorted()
    }

    func retainedState(for path: String) -> CodexScanState? {
        lock.lock(); defer { lock.unlock() }
        return entries[path]?.codexState
    }

    func missingPathCount(under roots: [String]) -> Int {
        Set(roots.flatMap { retainedPaths(under: $0) })
            .filter { !FileManager.default.fileExists(atPath: $0) }.count
    }

    /// Stat signature of a set of files, folding in size and mtime.
    ///
    /// Missing files contribute a stable placeholder so the signature stays
    /// comparable across scans (a `-wal` that is legitimately absent must not
    /// look like a change on every rescan).
    static func signature(of paths: [String]) -> String {
        var parts: [String] = []
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                parts.append("\(path)#-")
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(path)#\(size)#\(String(format: "%.6f", mtime))")
        }
        return parts.joined(separator: "|")
    }

    /// Returns the memoized buckets for `path`, or runs `compute` and stores it.
    ///
    /// `sidecars` are auxiliary files whose writes leave `path` itself untouched.
    /// A WAL-mode SQLite database is the motivating case: committed rows land in
    /// `-wal` and only reach the main file at a checkpoint, so keying freshness on
    /// the `.db` alone serves stale totals for as long as it takes a checkpoint to
    /// happen. See `DevinCollector`.
    func buckets(for path: String,
                 sidecars: [String] = [],
                 compute: (UInt64) -> [UsageBucket]) -> [UsageBucket] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            lock.lock(); defer { lock.unlock() }
            return entries[path]?.buckets ?? []
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        // Normalize empty to nil so entries cached before sidecars existed stay valid.
        let sig = Self.signature(of: sidecars)
        let storedSig = sig.isEmpty ? nil : sig

        lock.lock()
        if let hit = entries[path], hit.size == size, hit.mtime == mtime,
           hit.inode == inode, hit.sidecarSignature == storedSig {
            lock.unlock()
            return hit.buckets
        }
        lock.unlock()

        // Parse outside the lock: a rollout file can take seconds, and holding the
        // lock across it would serialize every other cache access behind it. Two
        // threads racing on the same path both compute and the last store wins,
        // which is harmless because the computation is a pure function of the file.
        let fresh = compute(size)

        lock.lock()
        entries[path] = CachedFileScan(size: size, mtime: mtime, inode: inode,
                                       sidecarSignature: storedSig, buckets: fresh,
                                       tailBuckets: nil, position: nil, codexState: nil,
                                       events: nil)
        dirty = true
        lock.unlock()
        return fresh
    }

    /// Like `buckets(for:compute:)`, but memoizes per-record events for
    /// collectors whose dedup unit spans files (Claude, pi).
    ///
    /// The caller still owns dedup: it concatenates events over every file in a
    /// deterministic order and collapses on `rid`. This method only guarantees
    /// "events for this file's current bytes" is cached.
    func events(for path: String,
                sidecars: [String] = [],
                compute: () -> [UsageEventRecord]) -> [UsageEventRecord] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            lock.lock(); defer { lock.unlock() }
            return entries[path]?.events ?? []
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let signature = Self.signature(of: sidecars)
        let storedSignature = signature.isEmpty ? nil : signature

        lock.lock()
        if let hit = entries[path], hit.size == size, hit.mtime == mtime,
           hit.inode == inode, hit.sidecarSignature == storedSignature, let events = hit.events {
            lock.unlock()
            return events
        }
        lock.unlock()

        // Parse outside the lock; see `buckets(for:compute:)`.
        let fresh = compute()

        lock.lock()
        entries[path] = CachedFileScan(size: size, mtime: mtime, inode: inode,
                                       sidecarSignature: storedSignature, buckets: [],
                                       tailBuckets: nil, position: nil, codexState: nil,
                                       events: fresh)
        dirty = true
        lock.unlock()
        return fresh
    }

    /// Like `buckets(for:compute:)`, but only parses bytes appended since the last
    /// scan when the file is append-only and grew.
    ///
    /// Used by `CodexCollector`, whose files are large and continuously written.
    /// Re-parsing a 294 MB rollout to add its newest turn costs ~0.4 s; resuming
    /// from the last offset costs milliseconds.
    ///
    /// Returns the buckets *including* the unterminated trailing segment, and an
    /// empty array if the file vanished. A read failure returns the previous
    /// answer rather than caching an empty one — memoising a transient failure
    /// under the file's current `(size, mtime)` would drop its usage until the
    /// file next changed.
    ///
    /// `baseline` is the parent's historical maximum offered to a forked rollout
    /// (see `CodexCollector`). A cached result is only valid while it was
    /// computed against the same baseline, so entries record what they used.
    func resumable(for path: String,
                   baseline: CodexUsageVec? = nil,
                   compute: (ResumePoint) -> ResumedBuckets?) -> ResumableOutcome {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path] else { return ResumableOutcome(buckets: [], state: nil) }
            return ResumableOutcome(buckets: mergeBuckets(entry.buckets + (entry.tailBuckets ?? [])),
                                    state: entry.codexState)
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        func combined(_ entry: CachedFileScan) -> ResumableOutcome {
            ResumableOutcome(buckets: mergeBuckets(entry.buckets + (entry.tailBuckets ?? [])),
                             state: entry.codexState)
        }

        // Entries without reducer state only carry a valid result for callers
        // that ask for no baseline; a fork whose parent appeared or vanished
        // since the last scan must recompute, not reuse.
        func baselineOK(_ state: CodexScanState?) -> Bool {
            (state?.baselineUsed ?? .zero) == (baseline ?? .zero)
        }

        lock.lock()
        let previous = entries[path]
        lock.unlock()

        if let hit = previous, hit.size == size, hit.mtime == mtime,
           hit.inode == inode, baselineOK(hit.codexState) {
            return combined(hit)
        }

        // Resume only when the file is the same one and merely longer, the
        // bytes before the recorded offset still fingerprint the same, and the
        // reducer state needed mid-file actually exists.
        var carried: [UsageBucket] = []
        var point = ResumePoint(startOffset: 0, state: nil)
        if let hit = previous, hit.inode == inode, size > hit.size,
           let position = hit.position, hit.codexState != nil,
           baselineOK(hit.codexState),
           Self.guardMatches(path: path, position: position) {
            point = ResumePoint(startOffset: position.resumeOffset, state: hit.codexState)
            carried = hit.buckets
        }

        guard let fresh = compute(point) else {
            return previous.map(combined) ?? ResumableOutcome(buckets: [], state: nil)
        }

        lock.lock()
        entries[path] = CachedFileScan(size: size, mtime: mtime, inode: inode,
                                       sidecarSignature: nil,
                                       buckets: carried + fresh.buckets,
                                       tailBuckets: fresh.tailBuckets,
                                       position: fresh.position,
                                       codexState: fresh.state,
                                       events: nil)
        dirty = true
        lock.unlock()

        return ResumableOutcome(buckets: mergeBuckets(carried + fresh.buckets + fresh.tailBuckets),
                                state: fresh.state)
    }

    /// Whether the bytes immediately before `position.resumeOffset` still hash the
    /// same as when the position was recorded.
    static func guardMatches(path: String, position: ScanPosition) -> Bool {
        let length = position.guardLength
        guard length > 0, length <= guardLength,
              position.resumeOffset >= UInt64(length) else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: position.resumeOffset - UInt64(length))) != nil,
              let window = try? handle.read(upToCount: length),
              window.count == length else { return false }
        return FNV1a.hash(window) == position.guardHash
    }

    /// Fingerprint the bytes ending at `offset`, for storing in a `ScanPosition`.
    static func guardWindow(for path: String, endingAt offset: UInt64) -> (length: Int, hash: UInt32) {
        let length = Int(min(UInt64(guardLength), offset))
        guard length > 0, let handle = FileHandle(forReadingAtPath: path) else { return (0, 0) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset - UInt64(length))) != nil,
              let window = try? handle.read(upToCount: length),
              window.count == length else { return (0, 0) }
        return (length, FNV1a.hash(window))
    }

    /// Persist the observed ledger, including disappeared logs. Clearing this
    /// cache intentionally reparses available files but preserves missing ones.
    func save(knownPaths: Set<String>) {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        let snapshot = Persisted(version: scanCacheVersion, files: entries)
        dirty = false
        lock.unlock()

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func clear() {
        lock.lock()
        entries = entries.filter { !FileManager.default.fileExists(atPath: $0.key) }
        dirty = true
        lock.unlock()
    }
}

// MARK: - Filesystem walking

enum FSWalk {
    /// All files under `root` matching `ext`, following the shallow directory
    /// layouts these CLIs use. Returns [] when root is missing.
    static func files(under root: String, ext: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                    includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == ext {
            out.append(url.path)
        }
        return out
    }
}
