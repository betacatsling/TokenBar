import Foundation

/// Which machine the usage came from.
enum Origin: String, Codable, CaseIterable, Hashable {
    case local
    case server1

    var displayName: String {
        switch self {
        case .local: return "本机"
        case .server1: return "server1"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "laptopcomputer"
        case .server1: return "server.rack"
        }
    }
}

/// Which CLI produced the usage.
enum CLIKind: String, Codable, CaseIterable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case devin
    case pi

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .devin: return "Devin CLI"
        case .pi: return "pi"
        }
    }

    /// Stable ordering for the UI.
    var sortIndex: Int {
        switch self {
        case .claudeCode: return 0
        case .codex: return 1
        case .devin: return 2
        case .pi: return 3
        }
    }
}

/// The four token buckets every provider reports in some form.
struct TokenCounts: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    /// Billable + cached total. Cache reads are real tokens the model processed,
    /// so they count toward the headline number.
    var total: Int { input + output + cacheRead + cacheWrite }

    static let zero = TokenCounts()

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Element-wise max. Claude Code writes progressive streaming snapshots of
    /// the same `message.id`; taking the max of each field recovers the final
    /// value without double counting. See ClaudeCodeCollector.
    func maxed(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(input, other.input),
                    output: Swift.max(output, other.output),
                    cacheRead: Swift.max(cacheRead, other.cacheRead),
                    cacheWrite: Swift.max(cacheWrite, other.cacheWrite))
    }
}

/// One usage-bearing record, kept at per-call granularity for cross-file
/// deduplication.
///
/// Transcripts get copied: Codex forks replay parent history, Claude
/// `--resume`/`--fork-session` writes a new file containing the old one, and
/// pi mirrors assistant rows into worker transcripts. Per-file buckets cannot
/// express "the same call appears in two files", so collectors with real
/// cross-file copies emit these instead; the collector then dedups on `rid`
/// before aggregating into `UsageBucket`s.
struct UsageEventRecord: Codable, Hashable {
    /// Stable identity of the underlying API call wherever it is written
    /// (e.g. `messageId:requestId`, `responseId`, or an entry-id fallback).
    var rid: String
    var model: String
    /// Local calendar day, `yyyy-MM-dd`.
    var day: String
    var isSidechain: Bool = false
    var tokens: TokenCounts
}

/// One aggregated bucket: a (origin, cli, model, day) tuple with its tokens.
/// Collectors emit these pre-grouped rather than per-message to keep the cache
/// small — a year of history stays in the low thousands of rows.
struct UsageBucket: Codable, Hashable {
    var origin: Origin
    var cli: CLIKind
    var model: String
    /// Local calendar day, `yyyy-MM-dd`.
    var day: String
    var tokens: TokenCounts
    /// Claude Code subagent (sidechain) traffic, tracked so the UI can exclude it.
    var isSidechain: Bool = false

    var groupKey: BucketKey {
        BucketKey(origin: origin, cli: cli, model: model, day: day, isSidechain: isSidechain)
    }
}

struct BucketKey: Codable, Hashable {
    var origin: Origin
    var cli: CLIKind
    var model: String
    var day: String
    var isSidechain: Bool
}

/// Merge buckets that share a key. Collectors and the remote decoder both feed
/// through this so totals never depend on emission granularity.
func mergeBuckets(_ buckets: [UsageBucket]) -> [UsageBucket] {
    var acc: [BucketKey: TokenCounts] = [:]
    acc.reserveCapacity(buckets.count)
    for b in buckets {
        acc[b.groupKey, default: .zero] += b.tokens
    }
    return acc.map { key, tokens in
        UsageBucket(origin: key.origin, cli: key.cli, model: key.model,
                    day: key.day, tokens: tokens, isSidechain: key.isSidechain)
    }
}

// MARK: - Date helpers

enum DayFormatter {
    /// `yyyy-MM-dd` in the user's local timezone, which is what "今日" should mean.
    static let local: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// Parses the ISO-8601 stamps the CLIs write (with or without fractional seconds).
    static func day(fromISO iso: String) -> String? {
        guard let date = ISO8601Parser.date(from: iso) else { return nil }
        return local.string(from: date)
    }

    static func day(fromUnixSeconds seconds: Double) -> String {
        local.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func today() -> String { local.string(from: Date()) }

    /// The last `count` days ending today, oldest first.
    static func recentDays(_ count: Int) -> [String] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: start).map { local.string(from: $0) }
        }
    }
}

enum ISO8601Parser {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
