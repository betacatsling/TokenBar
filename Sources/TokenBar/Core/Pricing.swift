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
    var cacheWrite1h: Double? = nil

    enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite, isInferred, cacheWrite1h }
    init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double,
         isInferred: Bool = false, cacheWrite1h: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.isInferred = isInferred; self.cacheWrite1h = cacheWrite1h
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Double.self, forKey: .input)
        output = try c.decode(Double.self, forKey: .output)
        cacheRead = try c.decodeIfPresent(Double.self, forKey: .cacheRead) ?? input
        cacheWrite = try c.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? input
        isInferred = try c.decodeIfPresent(Bool.self, forKey: .isInferred) ?? false
        cacheWrite1h = try c.decodeIfPresent(Double.self, forKey: .cacheWrite1h)
    }
}

/// Explicit USD/M overrides and catalog variants. Dates are inclusive ISO days.
struct PriceOverride: Codable {
    var model: String
    var price: ModelPrice
    var provider: String? = nil
    var pricingTier: String? = nil
    var serviceTier: String? = nil
    var speed: String? = nil
    var inferenceGeo: String? = nil
    var effectiveFrom: String? = nil
    var effectiveUntil: String? = nil
    /// Omitted means USD; non-USD entries are rejected, never converted silently.
    var currency: String? = nil
}

/// Cost estimation.
///
/// Dated local overrides take precedence; pi prices apply only to their actual
/// provider. The bundled catalog supplies standard rates, with built-in and
/// inferred rates filling missing models only. Undated prices express current
/// equivalent cost, not historical invoices. All rates and totals are USD.
///
/// Every figure the UI shows is prefixed with `≈` because this remains an
/// estimate: it records what a request *would* cost at list price, which is not
/// what a subscription or a discounted gateway actually bills.
struct Pricing {
    private var table: [String: ModelPrice]
    private var providerPrices: [String: ModelPrice]
    private var overrides: [PriceOverride]
    private(set) var issues: [String] = []
    /// Bare or family names that are genuinely ambiguous, so they are reported as
    /// unpriced rather than guessed at. Matching `gpt-5` as a prefix of
    /// `gpt-5.6-sol`, for instance, would silently apply the wrong generation's
    /// rates — which is why lookup is exact-match only.
    private static let unpriceable: Set<String> = [
        "<synthetic>", "synthetic", "unknown", "gpt-unknown",
        "opus", "sonnet", "haiku", "fable",
    ]

    init(table: [String: ModelPrice] = [:], providerPrices: [String: ModelPrice] = [:],
         overrides: [PriceOverride] = []) {
        self.table = Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.providerPrices = Dictionary(providerPrices.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.overrides = overrides
    }

    /// Load current-equivalent catalog rates and optional dated USD overrides.
    static func loadDefault(overridesURL: URL? = nil) -> Pricing {
        // Published catalog prices win; fallbacks fill missing exact models.
        var table = loadCatalog()
        // Between the catalog and the curated rates: an inference must never
        // override a published price, but should still fill a gap the catalog
        // leaves open.
        for (id, price) in inferred where table[id] == nil {
            table[id] = price
        }
        for (id, price) in builtIn where table[id] == nil {
            table[id.lowercased()] = price
        }
        let path = NSHomeDirectory() + "/Library/Application Support/TokenBar/pricing-overrides.json"
        let url = overridesURL ?? URL(fileURLWithPath: path)
        var local: [PriceOverride] = []
        var issues: [String] = []
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                local = try JSONDecoder().decode([PriceOverride].self, from: Data(contentsOf: url))
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                local = local.filter { rule in
                    let dates = [rule.effectiveFrom, rule.effectiveUntil].compactMap { $0 }
                    let valid = !rule.model.isEmpty && (rule.currency == nil || rule.currency?.uppercased() == "USD")
                        && [rule.price.input, rule.price.output, rule.price.cacheRead, rule.price.cacheWrite,
                            rule.price.cacheWrite1h ?? 0].allSatisfy { $0.isFinite && $0 >= 0 }
                        && dates.allSatisfy { s in
                            dateFormatter.date(from: s).map { dateFormatter.string(from: $0) == s } ?? false
                        }
                        && (rule.effectiveFrom == nil || rule.effectiveUntil == nil || rule.effectiveFrom! <= rule.effectiveUntil!)
                    if !valid { issues.append("Invalid pricing override for \(rule.model)") }
                    return valid
                }
            } catch { issues.append("Could not read pricing overrides: \(error.localizedDescription)") }
        }
        var pricing = Pricing(table: table, providerPrices: piStorePrices(), overrides: catalogVariants() + local)
        pricing.issues = issues
        return pricing
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
            guard entry["i"] is NSNumber, entry["o"] is NSNumber,
                  input.isFinite, output.isFinite, input >= 0, output >= 0 else { continue }
            table[name.lowercased()] = ModelPrice(
                input: input,
                output: output,
                // Cached input at full input rate rather than free, when the
                // catalog does not say.
                cacheRead: (entry["r"] as? NSNumber)?.doubleValue ?? input,
                cacheWrite: (entry["w"] as? NSNumber)?.doubleValue ?? input,
                cacheWrite1h: (entry["w1h"] as? NSNumber)?.doubleValue
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

    private static func catalogVariants() -> [PriceOverride] {
        guard let url = catalogURL, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var rules: [PriceOverride] = []
        for (model, value) in root {
            guard let entry = value as? [String: Any], let variants = entry["v"] as? [[String: Any]] else { continue }
            for variant in variants {
                guard let i = variant["i"] as? Double, let o = variant["o"] as? Double else { continue }
                rules.append(PriceOverride(model: model,
                    price: ModelPrice(input: i, output: o, cacheRead: variant["r"] as? Double ?? i,
                                      cacheWrite: variant["w"] as? Double ?? i, cacheWrite1h: variant["w1h"] as? Double),
                    pricingTier: variant["pricingTier"] as? String, serviceTier: variant["serviceTier"] as? String,
                    speed: variant["speed"] as? String, inferenceGeo: variant["inferenceGeo"] as? String))
            }
        }
        return rules
    }

    /// pi keeps a genuine price list for the gateways it routes through
    /// (verified: `cost.input`/`output`/`cacheRead`/`cacheWrite` in $/M tokens).
    private static func piStorePrices() -> [String: ModelPrice] {
        let rootPath = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] ?? NSHomeDirectory() + "/.pi/agent"
        let path = rootPath + "/models-store.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var table: [String: ModelPrice] = [:]
        for (providerID, value) in root {
            guard let provider = value as? [String: Any],
                  let models = provider["models"] as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String,
                      let cost = model["cost"] as? [String: Any],
                      cost["input"] is NSNumber, cost["output"] is NSNumber,
                      (cost["currency"] as? String ?? "USD").uppercased() == "USD" else { continue }
                let price = ModelPrice(
                    input: (cost["input"] as? NSNumber)?.doubleValue ?? 0,
                    output: (cost["output"] as? NSNumber)?.doubleValue ?? 0,
                    cacheRead: (cost["cacheRead"] as? NSNumber)?.doubleValue ?? (cost["input"] as? NSNumber)?.doubleValue ?? 0,
                    cacheWrite: (cost["cacheWrite"] as? NSNumber)?.doubleValue ?? (cost["input"] as? NSNumber)?.doubleValue ?? 0,
                    cacheWrite1h: (cost["cacheWrite1h"] as? NSNumber)?.doubleValue
                )
                guard price.input >= 0, price.output >= 0 else { continue }
                table["\(providerID)/\(id)".lowercased()] = price
            }
        }
        return table
    }

    /// USD per million tokens for the models this machine actually uses.
    static let builtIn: [String: ModelPrice] = [
        "claude-opus-5":   ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWrite1h: 4),
        "claude-haiku-4-5-20251001": ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25, cacheWrite1h: 2),
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWrite1h: 20),
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
    /// Exact model/provider matching. `[1m]` selects long-context pricing; an
    /// unavailable tier is unpriced rather than silently priced as standard.
    func price(for model: String, provider: String? = nil, pricingTier: String? = nil,
               serviceTier: String? = nil, speed: String? = nil, inferenceGeo: String? = nil,
               day: String? = nil) -> ModelPrice? {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tier = pricingTier ?? (key.contains("[1m]") ? "long-context" : nil)
        if let bracket = key.firstIndex(of: "[") { key = String(key[key.startIndex..<bracket]) }
        guard !key.isEmpty else { return nil }

        let bare = key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
        guard !Self.unpriceable.contains(bare) else { return nil }
        let provider = provider?.lowercased()
        let dimensions = [tier, serviceTier, speed, inferenceGeo].map { value -> String? in
            guard let value = value?.lowercased(), !["", "standard", "default", "normal", "global"].contains(value) else { return nil }
            return value
        }
        let date = day ?? DayFormatter.today()
        // Matching overrides must describe the full tier, so fast/geo pricing
        // never silently uses a standard rate. Most specific, latest date wins.
        let matches = overrides.enumerated().filter { _, rule in
            let name = rule.model.lowercased()
            return (name == key || name == provider.map { $0 + "/" + key })
                && (rule.provider == nil || rule.provider?.lowercased() == provider)
                && [rule.pricingTier, rule.serviceTier, rule.speed, rule.inferenceGeo].map {
                    value -> String? in
                    guard let value = value?.lowercased(), !["", "standard", "default", "normal", "global"].contains(value) else { return nil }
                    return value
                } == dimensions
                && (rule.effectiveFrom == nil || rule.effectiveFrom! <= date)
                && (rule.effectiveUntil == nil || rule.effectiveUntil! >= date)
        }.sorted { a, b in
            if (a.element.provider != nil) != (b.element.provider != nil) { return a.element.provider != nil }
            if a.element.effectiveFrom != b.element.effectiveFrom { return (a.element.effectiveFrom ?? "") > (b.element.effectiveFrom ?? "") }
            return a.offset > b.offset
        }
        var result: ModelPrice?
        var usesPiPrice = false
        if let rule = matches.first { result = rule.element.price }
        else if dimensions.contains(where: { $0 != nil }) {
            return officialClaudeVariant(key: key, provider: provider, dimensions: dimensions, day: date)
        }
        else if let provider {
            let scoped = key.hasPrefix(provider + "/") ? key : provider + "/" + key
            result = providerPrices[scoped] ?? table[scoped]
            usesPiPrice = providerPrices[scoped] != nil
            if result == nil, ["anthropic", "openai", "google", "devin"].contains(provider) {
                result = table[key] ?? table[bare]
            }
        } else {
            // A qualified model is an explicit provider selection. Never strip
            // an unknown provider prefix and substitute another provider's rate.
            result = providerPrices[key] ?? table[key]
            usesPiPrice = providerPrices[key] != nil
            if result == nil, !key.contains("/") {
                let candidates = table.filter { $0.key.hasSuffix("/" + key) }.map(\.value)
                if let first = candidates.first, candidates.allSatisfy({ $0 == first }) { result = first }
            }
        }
        if var price = result, price.cacheWrite1h == nil, bare.hasPrefix("claude-"), !usesPiPrice {
            price.cacheWrite1h = price.input * 2
            return price
        }
        return result
    }

    /// Verified https://platform.claude.com/docs/en/about-claude/pricing.
    /// An exact allowlist avoids extrapolating rates to unknown future models.
    private func officialClaudeVariant(key: String, provider: String?, dimensions: [String?], day: String) -> ModelPrice? {
        guard provider == nil || provider == "anthropic",
              !key.contains("/") || key.hasPrefix("anthropic/") else { return nil }
        let bare = key.hasPrefix("anthropic/") ? String(key.dropFirst(10)) : key
        let modern: Set<String> = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
            "claude-opus-5", "claude-opus-5-5", "claude-sonnet-4-6", "claude-sonnet-5",
            "claude-sonnet-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5",
            "claude-mythos-5-1", "claude-mythos-preview"]
        let known = modern.union(["claude-opus-4", "claude-opus-4-1", "claude-opus-4-5",
            "claude-sonnet-4", "claude-sonnet-4-5", "claude-haiku-3-5", "claude-haiku-4-5"])
        let name = known.first { bare == $0 || (bare.hasPrefix($0 + "-")
            && bare.dropFirst($0.count + 1).count == 8 && bare.dropFirst($0.count + 1).allSatisfy(\.isNumber)) }
        guard let name, dimensions[0] == nil || (dimensions[0] == "long-context" && modern.contains(name)),
              dimensions[1] == nil || ["batch", "batches"].contains(dimensions[1]!),
              dimensions[2] == nil || dimensions[2] == "fast",
              dimensions[3] == nil || (dimensions[3] == "us" && modern.contains(name)),
              var price = price(for: key, provider: provider, day: day) else { return nil }
        // A pi-configured provider has its own rates, even if named anthropic.
        let scoped = provider.map { key.hasPrefix($0 + "/") ? key : $0 + "/" + key } ?? key
        guard providerPrices[scoped] == nil else { return nil }
        var factor = 1.0
        if dimensions[2] == "fast" {
            guard dimensions[1] == nil else { return nil }
            if ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains(name) { factor *= 2 }
            else if name != "claude-opus-4-6" { return nil }
        }
        if dimensions[1] != nil { factor *= 0.5 }
        if dimensions[3] == "us" { factor *= 1.1 }
        price.input *= factor; price.output *= factor
        price.cacheRead *= factor; price.cacheWrite *= factor
        price.cacheWrite1h = price.cacheWrite1h.map { $0 * factor }
        return price
    }

    /// Cost in USD, or nil when the model is unpriced.
    func cost(of tokens: TokenCounts, model: String, provider: String? = nil,
              pricingTier: String? = nil, serviceTier: String? = nil, speed: String? = nil,
              inferenceGeo: String? = nil, day: String? = nil) -> Double? {
        guard let p = price(for: model, provider: provider, pricingTier: pricingTier,
                            serviceTier: serviceTier, speed: speed, inferenceGeo: inferenceGeo, day: day),
              tokens.cacheWrite1h == 0 || p.cacheWrite1h != nil,
              [p.input, p.output, p.cacheRead, p.cacheWrite, p.cacheWrite1h ?? 0].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let perMillion = 1_000_000.0
        return Double(tokens.input) / perMillion * p.input
            + Double(tokens.output) / perMillion * p.output
            + Double(tokens.cacheRead) / perMillion * p.cacheRead
            + Double(tokens.cacheWrite) / perMillion * p.cacheWrite
            + Double(tokens.cacheWrite1h) / perMillion * (p.cacheWrite1h ?? 0)
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
    /// Client-reported USD estimates, informational and never added to `usd`.
    var reportedUSD: Double = 0
    var reportedTokens: Int = 0

    /// True when some observed tokens had no matching price. Coverage says
    /// nothing about missing histories or actual invoices.
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
                     totalTokens: a.totalTokens + b.totalTokens,
                     reportedUSD: a.reportedUSD + b.reportedUSD,
                     reportedTokens: a.reportedTokens + b.reportedTokens)
    }

    static func += (a: inout CostEstimate, b: CostEstimate) { a = a + b }
}

extension Pricing {
    func estimate(_ buckets: [UsageBucket]) -> CostEstimate {
        var est = CostEstimate()
        for b in buckets {
            est.totalTokens += b.tokens.total
            if let reported = b.reportedCostUSD, reported.isFinite, reported >= 0 {
                est.reportedUSD += reported
                est.reportedTokens += b.tokens.total
            }
            if let c = cost(of: b.tokens, model: b.model, provider: b.provider,
                            pricingTier: b.pricingTier, serviceTier: b.serviceTier,
                            speed: b.speed, inferenceGeo: b.inferenceGeo, day: b.day) {
                est.usd += c
                if price(for: b.model, provider: b.provider, pricingTier: b.pricingTier,
                         serviceTier: b.serviceTier, speed: b.speed, inferenceGeo: b.inferenceGeo,
                         day: b.day)?.isInferred == true {
                    est.inferredTokens += b.tokens.total
                }
            } else {
                est.unpricedTokens += b.tokens.total
            }
        }
        return est
    }
}
