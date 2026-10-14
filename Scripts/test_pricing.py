#!/usr/bin/env python3
"""Run pricing/schema/collector regressions against production Swift, plus refresh.

python3 Scripts/test_pricing.py
Uses temporary fixtures only; does not modify user logs, cache, or price files.
"""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("refresh_prices", ROOT / "Scripts/refresh_prices.py")
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)
remote_spec = importlib.util.spec_from_file_location("remote_collect", ROOT / "Sources/TokenBar/Resources/remote_collect.py")
remote = importlib.util.module_from_spec(remote_spec)
remote_spec.loader.exec_module(remote)

SWIFT = r'''
import Foundation
import SQLite3

@main struct PricingTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { fatalError("FAILED: " + label) }
    }
    static func near(_ value: Double?, _ expected: Double, _ label: String) {
        check(value.map { abs($0 - expected) < 1e-9 } ?? false, label)
    }
    static func main() throws {
        let root = CommandLine.arguments[1]
        let million = TokenCounts(input: 1_000_000, output: 1_000_000,
                                  cacheRead: 1_000_000, cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)
        let old = try JSONDecoder().decode(TokenCounts.self, from: Data(#"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}"#.utf8))
        check(old.cacheWrite1h == 0 && old.total == 10, "old token cache")
        check((old + TokenCounts(cacheWrite1h: 7)).total == 17, "TTL sum")
        check(old.maxed(with: TokenCounts(cacheWrite1h: 7)).cacheWrite1h == 7, "TTL max")
        check(try JSONDecoder().decode(TokenCounts.self, from: JSONEncoder().encode(million)) == million, "token roundtrip")
        let legacyBucket = try JSONDecoder().decode(UsageBucket.self, from: Data(#"{"origin":"local","cli":"pi","model":"m","day":"2026-10-01","tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4},"isSidechain":false}"#.utf8))
        check(legacyBucket.provider == nil && legacyBucket.reportedCostUSD == nil, "old bucket cache")
        let legacyEvent = try JSONDecoder().decode(UsageEventRecord.self, from: Data(#"{"rid":"r","model":"m","day":"2026-10-01","tokens":{"input":1},"isSidechain":false}"#.utf8))
        check(legacyEvent.provider == nil && legacyEvent.tokens.cacheWrite1h == 0, "old event cache")
        let defaultPricing = Pricing.loadDefault(overridesURL: URL(fileURLWithPath: root + "/missing.json"))
        near(defaultPricing.cost(of: million, model: "claude-opus-5"), 46.75, "Opus5 actual categories")
        near(defaultPricing.cost(of: million, model: "claude-fable-5-1"), 92.75, "Fable5.1 actual categories")
        near(defaultPricing.price(for: "claude-sonnet-5")?.input, 2, "catalog beats stale builtin")
        near(defaultPricing.price(for: "claude-opus-5", provider: "gateway")?.input, 99, "pi store scoped rate survives")
        near(defaultPricing.price(for: "free-gateway", provider: "gateway")?.input, 0, "pi store explicit free")
        check(defaultPricing.price(for: "exclusive-gateway") == nil, "pi-only alias cannot leak")
        check(defaultPricing.price(for: "eur-gateway", provider: "gateway") == nil, "non USD pi rate rejected")
        near(defaultPricing.cost(of: million, model: "claude-opus-5[1m]"), 46.75, "modern long context")
        near(defaultPricing.cost(of: million, model: "claude-opus-5", speed: "fast", inferenceGeo: "us"), 102.85, "fast US all categories")
        near(defaultPricing.cost(of: million, model: "claude-fable-5-1", pricingTier: "long-context", serviceTier: "batch", inferenceGeo: "us"), 51.0125, "batch US cache and fable rates")
        check(defaultPricing.price(for: "claude-opus-5", serviceTier: "batch", speed: "fast") == nil, "fast batch incompatible")
        check(defaultPricing.price(for: "claude-opus-4-7", speed: "fast") == nil, "unsupported fast")
        near(defaultPricing.price(for: "claude-opus-4-6", speed: "fast")?.input, 5, "4.6 fast standard fallback")
        check(defaultPricing.price(for: "claude-opus-99-latest") == nil, "unknown future")
        check(defaultPricing.price(for: "claude-opus-5", provider: "vertex_ai", speed: "fast") == nil, "no first party modifiers on partners")
        let standard = ModelPrice(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1.25)
        let gateway = ModelPrice(input: 9, output: 10, cacheRead: 8, cacheWrite: 7, cacheWrite1h: 6)
        let free = ModelPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0)
        let p = Pricing(table: ["m": standard, "a/conflict": standard, "b/conflict": gateway,
                                "a/same": standard, "b/same": standard, "free": free],
                        providerPrices: ["gateway/m": gateway, "gateway/exclusive": gateway])
        near(p.cost(of: TokenCounts(input: 1_000_000), model: "m"), 1, "providerless standard")
        near(p.cost(of: million, model: "m", provider: "gateway"), 40, "scoped gateway")
        check(p.price(for: "exclusive") == nil, "pi does not leak cross CLI")
        check(p.price(for: "conflict") == nil, "ambiguous naked alias")
        check(p.price(for: "same") == standard, "unambiguous alias")
        check(p.price(for: "other/m") == nil, "no provider stripping")
        near(p.cost(of: million, model: "free"), 0, "explicit free priced")
        check(p.cost(of: million, model: "m") == nil, "unknown 1h rate")
        var b = UsageBucket(origin: .local, cli: .pi, model: "m", day: "2026-10-01", tokens: TokenCounts(input: 1_000_000))
        check(mergeBuckets([b, b]).first?.reportedCostUSD == nil, "nil reported remains nil")
        b.reportedCostUSD = 7; b.costSource = "client-reported-estimate"
        let merged = mergeBuckets([b, b])[0]
        near(merged.reportedCostUSD, 14, "merge reported once")
        let est = p.estimate([merged])
        near(est.usd, 2, "reported not added to estimate")
        near(est.reportedUSD, 14, "reported separate")
        check(est.reportedTokens == 2_000_000 && est.unpricedTokens == 0, "reported coverage")
        near((est + est).reportedUSD, 28, "estimate addition")
        var unknown = b; unknown.model = "unpriced"
        let unknownEst = p.estimate([unknown])
        check(unknownEst.unpricedTokens == unknown.tokens.total && unknownEst.reportedUSD == 7, "reported does not price unknown")
        for field in ["provider", "pricingTier", "serviceTier", "speed", "inferenceGeo", "costSource"] {
            var other = b
            switch field {
            case "provider": other.provider = "gateway"
            case "pricingTier": other.pricingTier = "long-context"
            case "serviceTier": other.serviceTier = "batch"
            case "speed": other.speed = "fast"
            case "inferenceGeo": other.inferenceGeo = "us"
            default: other.costSource = "other-estimate"
            }
            check(mergeBuckets([b, other]).count == 2, "dimension group " + field)
        }
        let overrides = [PriceOverride(model: "m", price: gateway, provider: "gateway", pricingTier: "long-context", serviceTier: "priority", speed: "fast", inferenceGeo: "us", effectiveFrom: "2026-09-01", effectiveUntil: "2026-09-30")]
        let tierPricing = Pricing(table: ["m": standard], overrides: overrides)
        near(tierPricing.cost(of: million, model: "m", provider: "gateway", pricingTier: "long-context", serviceTier: "priority", speed: "fast", inferenceGeo: "us", day: "2026-09-30"), 40, "all dimensions dated override")
        check(tierPricing.price(for: "m", provider: "gateway", pricingTier: "long-context", serviceTier: "priority", speed: "fast", inferenceGeo: "us", day: "2026-10-01") == nil, "override expiry")
        let overrideURL = URL(fileURLWithPath: root + "/overrides.json")
        try JSONEncoder().encode(overrides).write(to: overrideURL)
        near(Pricing.loadDefault(overridesURL: overrideURL).price(for: "m", provider: "gateway", pricingTier: "long-context", serviceTier: "priority", speed: "fast", inferenceGeo: "us", day: "2026-09-01")?.input, 9, "override file boundary")
        try Data("broken".utf8).write(to: overrideURL)
        check(!Pricing.loadDefault(overridesURL: overrideURL).issues.isEmpty, "override parse issue")
        var invalid = overrides[0]; invalid.currency = "EUR"
        try JSONEncoder().encode([invalid]).write(to: overrideURL)
        check(!Pricing.loadDefault(overridesURL: overrideURL).issues.isEmpty, "override non USD issue")
        invalid.currency = "USD"; invalid.effectiveFrom = "2026-02-31"
        try JSONEncoder().encode([invalid]).write(to: overrideURL)
        check(!Pricing.loadDefault(overridesURL: overrideURL).issues.isEmpty, "invalid override date")
        let pi = PiCollector.scanEvents(path: root + "/pi.jsonl")
        check(pi.count == 2 && pi[0].provider == "gateway" && pi[0].model == "served", "pi served metadata")
        check(pi[0].tokens.cacheWrite == 4 && pi[0].tokens.cacheWrite1h == 5, "pi cache split")
        near(pi[0].reportedCostUSD, 0.25, "pi client cost")
        check(pi[0].costSource == "client-reported-estimate" && pi[1].reportedCostUSD == nil, "USD only reported")
        let claude = ClaudeCodeCollector.scanEvents(path: root + "/claude.jsonl")
        check(claude.count == 1 && claude[0].tokens.cacheWrite == 10 && claude[0].tokens.cacheWrite1h == 20, "Claude TTL snapshots")
        check(claude[0].pricingTier == "long-context" && claude[0].serviceTier == "batch", "Claude tier metadata")
        let devin = DevinCollector.scan(dbPath: root + "/devin?#%.db", origin: .local)
        check(devin.count == 1 && devin[0].tokens.cacheWrite1h == 5 && devin[0].provider == "gateway", "Devin URI and metadata")
        let fm = FileManager.default
        let cache = ScanCache(url: URL(fileURLWithPath: root + "/test-cache.json"))
        let pc = PiCollector(); let cc = ClaudeCodeCollector(); let dc = DevinCollector()
        let piPath = pc.root + "/sessions/retained.jsonl"
        let claudePath = cc.root + "/retained.jsonl"
        for path in [piPath, claudePath, dc.dbPath] {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try fm.copyItem(atPath: root + "/pi.jsonl", toPath: piPath)
        try fm.copyItem(atPath: root + "/claude.jsonl", toPath: claudePath)
        try fm.copyItem(atPath: root + "/devin?#%.db", toPath: dc.dbPath)
        let piBuckets = pc.collect(cache: cache); let claudeBuckets = cc.collect(cache: cache); let devinBuckets = dc.collect(cache: cache)
        try JSONEncoder().encode(piBuckets + claudeBuckets + devinBuckets)
            .write(to: URL(fileURLWithPath: root + "/swift-parity.json"))
        check(!piBuckets.isEmpty && !claudeBuckets.isEmpty && !devinBuckets.isEmpty, "collect live fixtures")
        for path in [piPath, claudePath, dc.dbPath] { try fm.removeItem(atPath: path) }
        let retainedPi = pc.collect(cache: cache)
        if Set(retainedPi) != Set(piBuckets) {
            print("PI live", String(data: try JSONEncoder().encode(piBuckets), encoding: .utf8)!)
            print("PI retained", String(data: try JSONEncoder().encode(retainedPi), encoding: .utf8)!)
            print("PI paths", cache.retainedPaths(under: root), pc.root)
            print("ALL paths", cache.retainedPaths(under: "/"), URL(fileURLWithPath: pc.root + "/sessions").resolvingSymlinksInPath().path)
            fflush(stdout)
        }
        check(Set(retainedPi) == Set(piBuckets), "pi missing logs retained")
        check(Set(cc.collect(cache: cache)) == Set(claudeBuckets), "Claude missing logs retained")
        check(Set(dc.collect(cache: cache)) == Set(devinBuckets), "Devin missing DB retained")
        check(CLIKind.gemini.displayName == "Gemini CLI" && CLIKind.opencode.sortIndex == 5 && CLIKind.magpie.sortIndex == 6, "new CLI schema")
        print("Swift pricing/schema/collector checks passed: \(checks)")
    }
}
'''


class RefreshTests(unittest.TestCase):
    def test_free_and_unknown(self):
        self.assertEqual(refresh.convert({"input_cost_per_token": 0, "output_cost_per_token": 0}), {"i": 0, "o": 0})
        for bad in [{}, {"input_cost_per_token": 1}, {"input_cost_per_token": -1, "output_cost_per_token": 1},
                    {"input_cost_per_token": float("nan"), "output_cost_per_token": 1}]:
            self.assertIsNone(refresh.convert(bad))

    def test_cache_and_tiers(self):
        raw = {"input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6,
               "cache_read_input_token_cost": 0, "cache_creation_input_token_cost": 6.25e-6,
               "cache_creation_input_token_cost_above_1hr": 10e-6,
               "input_cost_per_token_priority": 10e-6, "output_cost_per_token_priority": 50e-6,
               "cache_read_input_token_cost_priority": 1e-6,
               "input_cost_per_token_above_200k_tokens": 8e-6, "output_cost_per_token_above_200k_tokens": 40e-6}
        entry = refresh.convert(raw)
        self.assertEqual(entry["w1h"], 10)
        self.assertEqual(entry["r"], 0)
        self.assertEqual(entry["v"][0]["serviceTier"], "priority")
        self.assertEqual(entry["v"][1]["pricingTier"], "long-context")

    def test_provider_alias_conflicts(self):
        one = {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}
        two = {"input_cost_per_token": 9e-6, "output_cost_per_token": 10e-6}
        table, _ = refresh.build({"a/conflict": one, "b/conflict": two, "a/same": one, "b/same": one, "standard": one, "gateway/standard": two})
        self.assertNotIn("conflict", table)
        self.assertEqual(table["same"]["i"], 1)
        self.assertEqual(table["standard"]["i"], 1)

    def test_production_swift(self):
        import sqlite3
        with tempfile.TemporaryDirectory(prefix="tokenbar-pricing-test-") as tmp:
            base = Path(tmp)
            (base / "main.swift").write_text(SWIFT)
            (base / "models-store.json").write_text(json.dumps({"gateway": {"models": [
                {"id": "claude-opus-5", "cost": {"input": 99, "output": 100}},
                {"id": "free-gateway", "cost": {"input": 0, "output": 0}},
                {"id": "exclusive-gateway", "cost": {"input": 1, "output": 2}},
                {"id": "eur-gateway", "cost": {"input": 1, "output": 2, "currency": "EUR"}}]}}))
            messages = [{"type": "model_change", "modelId": "requested", "provider": "gateway"}]
            for currency in ["USD", "EUR"]:
                messages.append({"id": currency, "timestamp": "2026-10-01T00:00:00Z", "message": {
                    "model": "requested", "responseModel": "served", "usage": {
                        "input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "cacheWrite1h": 5,
                        "pricing_tier": "long-context", "serviceTier": "priority", "speed": "fast", "inference_geo": "us",
                        "cost": {"total": .25, "currency": currency}}}})
            (base / "pi.jsonl").write_text("\n".join(map(json.dumps, messages)))
            rows = []
            for output in [1, 2]:
                rows.append({"type": "assistant", "timestamp": "2026-10-01T00:00:00Z", "message": {
                    "id": "same", "model": "claude-opus-5[1m]", "usage": {"input_tokens": 1, "output_tokens": output,
                    "cache_creation_input_tokens": 30, "cache_creation": {"ephemeral_5m_input_tokens": 10,
                    "ephemeral_1h_input_tokens": 20}, "service_tier": "batch", "providerId": "anthropic",
                    "speed": "normal", "inference_geo": "us", "costUSD": output * .1}}})
            (base / "claude.jsonl").write_text("\n".join(map(json.dumps, rows)))
            with sqlite3.connect(base / "devin?#%.db") as db:
                db.executescript("CREATE TABLE sessions(id TEXT, model TEXT); CREATE TABLE message_nodes(row_id INTEGER, chat_message TEXT, created_at REAL, session_id TEXT); INSERT INTO sessions VALUES ('s','swe-2');")
                obj = {"role": "assistant", "message_id": "r", "metadata": {"generation_model": "swe-2-high", "provider": "gateway",
                    "pricingTier": "long-context", "service_tier": "priority", "speed": "fast", "inferenceGeo": "us", "cost_usd": .5,
                    "metrics": {"input_tokens": 1, "cache_creation_1h_tokens": 5}}}
                db.execute("INSERT INTO message_nodes VALUES (1, ?, 0, 's')", (json.dumps(obj),))
            sources = ["Core/UsageRecord.swift", "Core/Pricing.swift", "Core/BundledResource.swift", "Core/ScanCache.swift", "Core/CodexLineage.swift",
                       "Collectors/Collector.swift", "Collectors/ClaudeCodeCollector.swift", "Collectors/PiCollector.swift", "Collectors/DevinCollector.swift"]
            subprocess.run(["swiftc", "-parse-as-library", *[str(ROOT / "Sources/TokenBar" / s) for s in sources], str(base / "main.swift"), "-o", str(base / "test")], check=True)
            env = dict(os.environ, PI_CODING_AGENT_DIR=str(base), CLAUDE_CONFIG_DIR=str(base), XDG_DATA_HOME=str(base / "xdg?#%"))
            subprocess.run([str(base / "test"), str(base)], check=True, env=env)
            # The Swift retention tests removed their copies; recreate two
            # identical transcripts to also exercise remote cross-file dedup.
            for folder, name in [(base / "sessions", "pi"), (base / "projects", "claude")]:
                for copy in ["a", "b"]:
                    (folder / (copy + ".jsonl")).write_text((base / (name + ".jsonl")).read_text())
            buckets = (remote.collect_pi(str(base)) + remote.collect_claude(str(base / "projects"))
                       + remote.collect_devin(str(base / "devin?#%.db")))
            envelope = io.StringIO()
            with contextlib.redirect_stdout(envelope):
                remote.emit(buckets)
            actual = json.loads(envelope.getvalue())["buckets"]
            expected = json.loads((base / "swift-parity.json").read_text())
            fields = ["cli", "model", "day", "provider", "pricingTier", "serviceTier", "speed", "inferenceGeo", "costSource", "reportedCostUSD"]
            counts = ["input", "output", "cacheRead", "cacheWrite", "cacheWrite1h"]
            def normalize(bucket):
                return tuple(bucket.get(k) for k in fields) + (bucket.get("sidechain", bucket.get("isSidechain", False)),) + tuple(
                    bucket.get("tokens", bucket).get(k, 0) for k in counts)
            self.assertEqual(set(map(normalize, actual)), set(map(normalize, expected)))

    def test_remote_metadata(self):
        b = remote.apply_usage_metadata({"model": "claude-opus-5[1m]"},
            {"provider": "", "provider_id": "gateway", "reportedCostUSD": 0, "currency": "USD"})
        self.assertEqual(b["provider"], "gateway")
        self.assertEqual(b["pricingTier"], "long-context")
        self.assertEqual(b["reportedCostUSD"], 0)
        self.assertEqual(b["costSource"], "client-reported-estimate")
        for value, currency in [(float("nan"), "USD"), (float("inf"), "USD"), (-1, "USD"), (1, "EUR")]:
            b = remote.apply_usage_metadata({"model": "m"}, {"costUSD": value, "currency": currency})
            self.assertNotIn("reportedCostUSD", b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
