import Foundation

/// Per-million-token prices for one model.
struct ModelPrice: Codable, Hashable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    /// True when this rate is reasoned about rather than published by the vendor
    /// — see `inferred` below. The UI marks these so an inference is never shown
    /// with the same confidence as a list price.
    var isInferred: Bool = false
}

/// Cost estimation.
///
/// Prices come from three layers, most specific first:
///
/// 1. `builtIn` — hand-curated first-party rates, kept for the models this app's
///    own logs show most, so a wrong catalog entry cannot move the headline number.
/// 2. `~/.pi/agent/models-store.json` — prices the user's gateway actually
///    configures. This is the only source for `glm-5.3`, `kimi-k3` and
///    `qwen3.8-max`, which appear in these logs in quantity and are absent from
///    the public catalog entirely.
/// 3. `Resources/model_prices.json` — a pruned snapshot of LiteLLM's
///    `model_prices_and_context_window.json`, the same table `ccusage` prices
///    against. 4,390 models.
///
/// Every figure the UI shows is prefixed with `≈` because this remains an
/// estimate: it records what a request *would* cost at list price, which is not
/// what a subscription or a discounted gateway actually bills.
struct Pricing {
    private var table: [String: ModelPrice]
    /// Bare or family names that are genuinely ambiguous, so they are reported as
    /// unpriced rather than guessed at. Matching `gpt-5` as a prefix of
    /// `gpt-5.6-sol`, for instance, would silently apply the wrong generation's
    /// rates — which is why lookup is exact-match only.
    private static let unpriceable: Set<String> = [
        "<synthetic>", "synthetic", "unknown", "gpt-unknown",
        "opus", "sonnet", "haiku", "fable",
    ]

    init(table: [String: ModelPrice] = [:]) {
        self.table = table
    }

    /// All three layers, merged.
    static func loadDefault() -> Pricing {
        // Weakest layer first; each later layer overwrites what came before.
        var table = loadCatalog()
        for (id, price) in piStorePrices() where price.input > 0 || price.output > 0 {
            table[id.lowercased()] = price
        }
        // Between the catalog and the curated rates: an inference must never
        // override a published price, but should still fill a gap the catalog
        // leaves open.
        for (id, price) in inferred where table[id] == nil {
            table[id] = price
        }
        for (id, price) in builtIn {
            table[id.lowercased()] = price
        }
        return Pricing(table: table)
    }

    /// The bundled LiteLLM snapshot.
    ///
    /// Bundled rather than fetched: this app is meant to work offline and to give
    /// the same answer twice, and a network fetch on every launch would break both.
    /// `Scripts/refresh_prices.py` regenerates the file.
    private static func loadCatalog() -> [String: ModelPrice] {
        guard let url = catalogURL, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var table: [String: ModelPrice] = [:]
        table.reserveCapacity(root.count)
        for (name, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let input = (entry["i"] as? NSNumber)?.doubleValue ?? 0
            let output = (entry["o"] as? NSNumber)?.doubleValue ?? 0
            // An entry pricing only one direction is dropped: a half-priced model
            // under-reports silently, which is worse than reporting it unpriced.
            guard input > 0 || output > 0 else { continue }
            table[name.lowercased()] = ModelPrice(
                input: input,
                output: output,
                // Cached input at full input rate rather than free, when the
                // catalog does not say.
                cacheRead: (entry["r"] as? NSNumber)?.doubleValue ?? input,
                cacheWrite: (entry["w"] as? NSNumber)?.doubleValue ?? input
            )
        }
        return table
    }

    /// Locate the bundled snapshot. See `BundledResource` for why this avoids
    /// `Bundle.module`.
    private static var catalogURL: URL? {
        BundledResource.url(named: "model_prices", ext: "json",
                            devAnchor: #filePath)
    }

    /// pi keeps a genuine price list for the gateways it routes through
    /// (verified: `cost.input`/`output`/`cacheRead`/`cacheWrite` in $/M tokens).
    private static func piStorePrices() -> [String: ModelPrice] {
        let path = NSHomeDirectory() + "/.pi/agent/models-store.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var table: [String: ModelPrice] = [:]
        for (_, value) in root {
            guard let provider = value as? [String: Any],
                  let models = provider["models"] as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String,
                      let cost = model["cost"] as? [String: Any] else { continue }
                let price = ModelPrice(
                    input: (cost["input"] as? NSNumber)?.doubleValue ?? 0,
                    output: (cost["output"] as? NSNumber)?.doubleValue ?? 0,
                    cacheRead: (cost["cacheRead"] as? NSNumber)?.doubleValue ?? 0,
                    cacheWrite: (cost["cacheWrite"] as? NSNumber)?.doubleValue ?? 0
                )
                guard price.input > 0 || price.output > 0 else { continue }
                table[id.lowercased()] = price
            }
        }
        return table
    }

    /// USD per million tokens for the models this machine actually uses.
    static let builtIn: [String: ModelPrice] = [
        "claude-opus-5":   ModelPrice(input: 15, output: 75, cacheRead: 1.5,  cacheWrite: 18.75),
        "claude-sonnet-5": ModelPrice(input: 3,  output: 15, cacheRead: 0.3,  cacheWrite: 3.75),
        "claude-haiku-4-5-20251001": ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-fable-5-1": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
    ]

    /// Rates carried over from a related model because the vendor publishes none.
    ///
    /// Devin's `swe-2-*` are post-trained from kimi-k3, so kimi-k3's rates are
    /// the closest defensible basis. Both sources this app already trusts agree
    /// on those rates — `~/.pi/agent/models-store.json` lists `kimi-k3` at
    /// 3 / 15 / 0.3 / 0 under two providers, and LiteLLM's `moonshot/kimi-k3`
    /// gives the same 3 / 15 / 0.3 — so the figure does not depend on which one
    /// is consulted.
    ///
    /// Written out rather than looked up through `kimi-k3` at runtime: a chained
    /// lookup would silently re-price swe-2 if the pi store were edited, and this
    /// number should only move when someone changes it deliberately.
    ///
    /// These carry `isInferred`, which the panel surfaces as 「按 kimi-k3 估算」.
    /// The figure says what the tokens would cost at kimi-k3's rate, nothing more.
    ///
    /// `swe-2-high` / `swe-2-max` are collapsed to `swe-2` at collection (they are
    /// effort tiers of one model, not two models), so the bare name is what the
    /// table is actually asked for; the tier names are kept as entries anyway, for
    /// buckets that predate the merge.
    ///
    /// Not listed: `compactor`, Devin's context-compaction model. There is no
    /// stated relationship to any priced model, so it stays unpriced (0.34% of
    /// server1's Devin tokens, 0.06% locally) rather than being folded into a
    /// rate it may not share.
    static let inferred: [String: ModelPrice] = {
        let kimiK3 = ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 0, isInferred: true)
        return ["swe-2": kimiK3, "swe-2-high": kimiK3, "swe-2-max": kimiK3]
    }()

    /// Prices for one model, or nil when no layer knows it.
    ///
    /// Exact-match only, after lowercasing, stripping a `[1m]`-style variant
    /// suffix (Claude Code writes those for the extended-context tier, which bills
    /// at the base rate) and, failing that, trying the bare name after any
    /// `provider/` prefix.
    func price(for model: String) -> ModelPrice? {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bracket = key.firstIndex(of: "[") { key = String(key[key.startIndex..<bracket]) }
        guard !key.isEmpty else { return nil }

        let bare = key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
        guard !Self.unpriceable.contains(bare) else { return nil }
        return table[key] ?? table[bare]
    }

    /// Cost in USD, or nil when the model is unpriced.
    func cost(of tokens: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        if p.input == 0 && p.output == 0 && p.cacheRead == 0 && p.cacheWrite == 0 { return nil }
        let perMillion = 1_000_000.0
        return Double(tokens.input) / perMillion * p.input
            + Double(tokens.output) / perMillion * p.output
            + Double(tokens.cacheRead) / perMillion * p.cacheRead
            + Double(tokens.cacheWrite) / perMillion * p.cacheWrite
    }
}

/// A cost figure that remembers how much of the underlying usage it could not price.
struct CostEstimate {
    var usd: Double = 0
    /// Tokens belonging to models with no known price.
    var unpricedTokens: Int = 0
    /// Tokens priced from an inferred rate (see `Pricing.inferred`) rather than a
    /// published one. Tracked separately so the panel can say which part of the
    /// figure rests on an assumption.
    var inferredTokens: Int = 0
    var totalTokens: Int = 0

    /// True when some usage had no price, so the number is a lower bound.
    var isPartial: Bool { unpricedTokens > 0 }

    /// True when any of the figure comes from an inferred rate.
    var hasInferred: Bool { inferredTokens > 0 }

    var coverage: Double {
        totalTokens > 0 ? Double(totalTokens - unpricedTokens) / Double(totalTokens) : 1
    }

    static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate {
        CostEstimate(usd: a.usd + b.usd,
                     unpricedTokens: a.unpricedTokens + b.unpricedTokens,
                     inferredTokens: a.inferredTokens + b.inferredTokens,
                     totalTokens: a.totalTokens + b.totalTokens)
    }

    static func += (a: inout CostEstimate, b: CostEstimate) { a = a + b }
}

extension Pricing {
    func estimate(_ buckets: [UsageBucket]) -> CostEstimate {
        var est = CostEstimate()
        for b in buckets {
            est.totalTokens += b.tokens.total
            if let c = cost(of: b.tokens, model: b.model) {
                est.usd += c
                if price(for: b.model)?.isInferred == true {
                    est.inferredTokens += b.tokens.total
                }
            } else {
                est.unpricedTokens += b.tokens.total
            }
        }
        return est
    }
}
