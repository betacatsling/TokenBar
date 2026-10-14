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
    case gemini
    case opencode
    case magpie

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .devin: return "Devin CLI"
        case .pi: return "pi"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .magpie: return "Magpie"
        }
    }

    /// Stable ordering for the UI.
    var sortIndex: Int {
        switch self {
        case .claudeCode: return 0
        case .codex: return 1
        case .devin: return 2
        case .pi: return 3
        case .gemini: return 4
        case .opencode: return 5
        case .magpie: return 6
        }
    }
}

/// The four token buckets every provider reports in some form.
struct TokenCounts: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var cacheWrite1h: Int = 0

    enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite, cacheWrite1h }

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
         cacheWrite: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
    }

    /// Billable + cached total. Cache reads are real tokens the model processed,
    /// so they count toward the headline number.
    var total: Int { input + output + cacheRead + cacheWrite + cacheWrite1h }

    static let zero = TokenCounts()

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Element-wise max. Claude Code writes progressive streaming snapshots of
    /// the same `message.id`; taking the max of each field recovers the final
    /// value without double counting. See ClaudeCodeCollector.
    func maxed(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(input, other.input),
                    output: Swift.max(output, other.output),
                    cacheRead: Swift.max(cacheRead, other.cacheRead),
                    cacheWrite: Swift.max(cacheWrite, other.cacheWrite),
                    cacheWrite1h: Swift.max(cacheWrite1h, other.cacheWrite1h))
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
    var provider: String? = nil
    var reportedCostUSD: Double? = nil
    var costSource: String? = nil
    var pricingTier: String? = nil
    var serviceTier: String? = nil
    var speed: String? = nil
    var inferenceGeo: String? = nil

    func bucket(origin: Origin, cli: CLIKind) -> UsageBucket {
        UsageBucket(origin: origin, cli: cli, model: model, day: day, tokens: tokens,
                    isSidechain: isSidechain, provider: provider, reportedCostUSD: reportedCostUSD,
                    costSource: costSource, pricingTier: pricingTier, serviceTier: serviceTier,
                    speed: speed, inferenceGeo: inferenceGeo)
    }

    func mergingSnapshot(with other: UsageEventRecord) -> UsageEventRecord {
        var result = self
        result.tokens = tokens.maxed(with: other.tokens)
        result.provider = other.provider ?? provider
        result.pricingTier = other.pricingTier ?? pricingTier
        result.serviceTier = other.serviceTier ?? serviceTier
        result.speed = other.speed ?? speed
        result.inferenceGeo = other.inferenceGeo ?? inferenceGeo
        result.costSource = other.costSource ?? costSource
        if let cost = other.reportedCostUSD { result.reportedCostUSD = Swift.max(reportedCostUSD ?? 0, cost) }
        return result
    }

    /// Reads only usage metadata, never configuration or credentials.
    mutating func applyMetadata(_ sources: [[String: Any]]) {
        func string(_ keys: [String]) -> String? {
            for source in sources {
                for key in keys {
                    if let s = source[key] as? String, !s.isEmpty { return s }
                }
            }
            return nil
        }
        provider = string(["provider", "providerId", "provider_id"])
        pricingTier = string(["pricingTier", "pricing_tier"])
            ?? (model.lowercased().contains("[1m]") ? "long-context" : nil)
        serviceTier = string(["serviceTier", "service_tier"])
        speed = string(["speed"])
        inferenceGeo = string(["inferenceGeo", "inference_geo"])
        costSource = string(["costSource", "cost_source"])
        let currency = string(["currency", "costCurrency", "cost_currency"])
        guard currency == nil || currency?.uppercased() == "USD" else { return }
        for source in sources {
            if let cost = (source["reportedCostUSD"] ?? source["costUSD"] ?? source["cost_usd"]) as? NSNumber,
               cost.doubleValue.isFinite, cost.doubleValue >= 0 {
                reportedCostUSD = cost.doubleValue
                costSource = "client-reported-estimate"
                break
            }
        }
    }
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
    var provider: String? = nil
    var reportedCostUSD: Double? = nil
    var costSource: String? = nil
    var pricingTier: String? = nil
    var serviceTier: String? = nil
    var speed: String? = nil
    var inferenceGeo: String? = nil

    var groupKey: BucketKey {
        BucketKey(origin: origin, cli: cli, model: model, day: day, isSidechain: isSidechain,
                  provider: provider, pricingTier: pricingTier, serviceTier: serviceTier,
                  speed: speed, inferenceGeo: inferenceGeo, costSource: costSource)
    }
}

struct BucketKey: Codable, Hashable {
    var origin: Origin
    var cli: CLIKind
    var model: String
    var day: String
    var isSidechain: Bool
    var provider: String? = nil
    var pricingTier: String? = nil
    var serviceTier: String? = nil
    var speed: String? = nil
    var inferenceGeo: String? = nil
    var costSource: String? = nil
}

/// Merge buckets that share a key. Collectors and the remote decoder both feed
/// through this so totals never depend on emission granularity.
func mergeBuckets(_ buckets: [UsageBucket]) -> [UsageBucket] {
    var acc: [BucketKey: UsageBucket] = [:]
    acc.reserveCapacity(buckets.count)
    for b in buckets {
        if var existing = acc[b.groupKey] {
            existing.tokens += b.tokens
            if let reported = b.reportedCostUSD {
                existing.reportedCostUSD = (existing.reportedCostUSD ?? 0) + reported
            }
            acc[b.groupKey] = existing
        } else {
            acc[b.groupKey] = b
        }
    }
    return Array(acc.values)
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
