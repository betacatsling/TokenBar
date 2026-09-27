import Foundation

/// Which time window the popover is showing.
enum TimeRange: String, CaseIterable, Identifiable {
    case today, week, month, all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "今日"
        case .week: return "7 天"
        case .month: return "30 天"
        case .all: return "全部"
        }
    }

    /// Days included, or nil for "all time".
    var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    func contains(day: String, today: String) -> Bool {
        guard let limit = days else { return true }
        guard let cutoff = DayFormatter.recentDays(limit).first else { return true }
        return day >= cutoff && day <= today
    }
}

/// A labelled total used by the breakdown lists.
struct BreakdownRow: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var tokens: TokenCounts
    var cost: CostEstimate
    /// Set for CLI rows so the view can draw the right icon.
    var cli: CLIKind?

    var total: Int { tokens.total }
}

/// The fully-computed view model the popover renders.
struct UsageSnapshot {
    var range: TimeRange
    var buckets: [UsageBucket]
    var pricing: Pricing
    var remoteStatus: RemoteStatus
    var remoteAsOf: Date?
    var scannedAt: Date
    /// Wall-clock duration of the last local scan.
    var scanDuration: TimeInterval
    /// True when subagent (sidechain) traffic is included.
    var includeSidechain: Bool

    static let empty = UsageSnapshot(
        range: .today, buckets: [], pricing: Pricing(), remoteStatus: .idle,
        remoteAsOf: nil, scannedAt: Date(), scanDuration: 0, includeSidechain: false
    )

    /// Buckets inside the selected range.
    var activeBuckets: [UsageBucket] {
        let today = DayFormatter.today()
        return buckets.filter { range.contains(day: $0.day, today: today) }
    }

    var totalTokens: Int { activeBuckets.reduce(0) { $0 + $1.tokens.total } }

    var totalCost: CostEstimate { pricing.estimate(activeBuckets) }

    /// Totals per CLI, ordered by the CLI's canonical position.
    var byCLI: [BreakdownRow] {
        group(activeBuckets, key: { $0.cli.rawValue }) { key, group in
            let cli = CLIKind(rawValue: key) ?? .claudeCode
            return BreakdownRow(id: key, title: cli.displayName, subtitle: nil,
                                tokens: group.reduce(.zero) { $0 + $1.tokens },
                                cost: pricing.estimate(group), cli: cli)
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// Totals per machine.
    var byOrigin: [BreakdownRow] {
        group(activeBuckets, key: { $0.origin.rawValue }) { key, group in
            let origin = Origin(rawValue: key) ?? .local
            return BreakdownRow(id: key, title: origin.displayName, subtitle: nil,
                                tokens: group.reduce(.zero) { $0 + $1.tokens },
                                cost: pricing.estimate(group), cli: nil)
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// Per-model totals, optionally scoped to one CLI.
    func byModel(cli: CLIKind? = nil) -> [BreakdownRow] {
        let source = cli.map { c in activeBuckets.filter { $0.cli == c } } ?? activeBuckets
        return group(source, key: { $0.model }) { key, group in
            let clis = Set(group.map { $0.cli })
            let subtitle = clis.count == 1 ? clis.first?.displayName : nil
            return BreakdownRow(id: key, title: key, subtitle: subtitle,
                                tokens: group.reduce(.zero) { $0 + $1.tokens },
                                cost: pricing.estimate(group), cli: clis.count == 1 ? clis.first : nil)
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// Daily totals for the sparkline, oldest first.
    func dailySeries(days: Int = 14) -> [Int] {
        let wanted = DayFormatter.recentDays(days)
        var totals: [String: Int] = [:]
        for b in buckets { totals[b.day, default: 0] += b.tokens.total }
        return wanted.map { totals[$0] ?? 0 }
    }

    /// All-time token total regardless of the selected range, for the "全部" label.
    var allTimeTokens: Int { buckets.reduce(0) { $0 + $1.tokens.total } }

    private func group(_ source: [UsageBucket],
                       key keyOf: (UsageBucket) -> String,
                       make: (String, [UsageBucket]) -> BreakdownRow) -> [BreakdownRow] {
        var acc: [String: [UsageBucket]] = [:]
        for b in source { acc[keyOf(b), default: []].append(b) }
        return acc.map { make($0.key, $0.value) }
    }
}

// MARK: - Aggregation entry point

/// Runs every collector and produces a snapshot.
final class Aggregator {
    private let cache: ScanCache
    let remote: RemoteCollector
    private let pricing: Pricing

    init(cache: ScanCache = ScanCache(),
         remote: RemoteCollector = RemoteCollector(),
         pricing: Pricing = Pricing.loadDefault()) {
        self.cache = cache
        self.remote = remote
        self.pricing = pricing
    }

    /// Local collectors, in display order.
    private var localCollectors: [Collector] {
        [ClaudeCodeCollector(), CodexCollector(), DevinCollector(), PiCollector()]
    }

    /// Scans the local machine. Safe to call off the main thread.
    func scanLocal(includeSidechain: Bool) -> (buckets: [UsageBucket], duration: TimeInterval) {
        let start = Date()
        var all: [UsageBucket] = []
        var known = Set<String>()

        for collector in localCollectors {
            let buckets = collector.collect(cache: cache)
            all += buckets
            known.formUnion(collector.discoverPaths())
        }

        // Drop cache rows for transcripts that have been deleted.
        cache.save(knownPaths: known)

        let filtered = includeSidechain ? all : all.filter { !$0.isSidechain }
        return (mergeBuckets(filtered), Date().timeIntervalSince(start))
    }

    /// Fetches server1 buckets, falling back to the last good result.
    func scanRemoteIfNeeded(force: Bool = false) -> [UsageBucket] {
        remote.fetchIfNeeded(force: force)
    }

    func snapshot(range: TimeRange,
                  includeSidechain: Bool,
                  localBuckets: [UsageBucket],
                  remoteBuckets: [UsageBucket],
                  duration: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            range: range,
            buckets: mergeBuckets(localBuckets + remoteBuckets),
            pricing: pricing,
            remoteStatus: remote.status,
            remoteAsOf: remote.lastKnownDate,
            scannedAt: Date(),
            scanDuration: duration,
            includeSidechain: includeSidechain
        )
    }

    func clearCache() { cache.clear() }
}
