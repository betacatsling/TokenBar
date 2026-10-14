#!/usr/bin/env python3
"""Known-answer fixtures for the production Swift and remote Python collectors.

Compiles a small driver around the real Swift collectors. All source roots,
SQLite stores and scan caches are temporary; never reads auth or writes live logs.
Run: python3 Scripts/test_additional_collection.py
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("remote_collect", ROOT / "Sources/TokenBar/Resources/remote_collect.py")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
TOKEN_FIELDS = ("input", "output", "cacheRead", "cacheWrite", "cacheWrite1h")

DRIVER = r'''
import Foundation
struct AdditionalEnvelope: Encodable {
    var buckets: [UsageBucket]
    var diagnostics: MagpieScanDiagnostics
}
@main struct AdditionalDriver {
    static func main() throws {
        let args = CommandLine.arguments
        let cache = ScanCache(url: URL(fileURLWithPath: args[1]))
        let exclusions = Set(args.dropFirst(2))
        let collectors: [Collector] = [GeminiCollector(), OpenCodeCollector()]
        var buckets = collectors.flatMap { $0.collect(cache: cache) }
        buckets += MagpieCollector().collect(cache: cache, excluding: exclusions)
        var paths = Set(collectors.flatMap { $0.discoverPaths() } + MagpieCollector().discoverPaths())
        for root in [GeminiCollector().root + "/tmp", OpenCodeCollector().root, MagpieCollector().root] {
            paths.formUnion(cache.retainedPaths(under: root))
        }
        cache.save(knownPaths: paths)
        let data = try JSONEncoder().encode(AdditionalEnvelope(
            buckets: mergeBuckets(buckets), diagnostics: MagpieCollector().scanDiagnostics(excluding: exclusions)))
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj), encoding="utf-8")


def open_message(identity, provider="openai", **changes):
    obj = {"id": identity, "role": "assistant", "modelID": "fixture-model",
           "providerID": provider, "time": {"created": 1790812800000},
           "tokens": {"input": 100, "output": 20, "reasoning": 10,
                      "cache": {"read": 40, "write": 5}}, "cost": 0}
    obj.update(changes)
    return obj


def magpie_message(identity="gateway-one", **changes):
    obj = {"t": "2026-10-01T00:00:00Z", "agent": "magpie",
           "response_id": identity, "request_id": "request-" + identity,
           "served": "fixture-gateway", "provider": "fixture-provider", "in": 100,
           "out": 10, "cache_read": 20, "cache_write": 5, "cache_write_1h": 3}
    obj.update(changes)
    return obj


class AdditionalCollectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="tokenbar-additional-driver-")
        base = Path(cls.build.name)
        driver = base / "Driver.swift"
        driver.write_text(DRIVER)
        cls.binary = base / "additional-driver"
        source = ROOT / "Sources/TokenBar"
        files = [source / p for p in (
            "Core/UsageRecord.swift", "Core/CodexLineage.swift", "Core/ScanCache.swift",
            "Collectors/Collector.swift", "Collectors/GeminiCollector.swift",
            "Collectors/OpenCodeCollector.swift", "Collectors/MagpieCollector.swift")]
        # Other agents may still be editing shared core files. Compile a private
        # read-only snapshot so Swift doesn't race with a concurrent file write.
        snapshots = []
        for path in files:
            snapshot = base / path.name
            snapshot.write_bytes(path.read_bytes())
            snapshots.append(snapshot)
        result = subprocess.run(["swiftc", "-O", "-parse-as-library"] + list(map(str, snapshots)) +
                                [str(driver), "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tokenbar-additional-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        # These override every collector root, including the app's main harness.
        self.env = dict(os.environ, TZ="Asia/Shanghai",
                        GEMINI_CLI_HOME=str(self.base / "gemini"),
                        MAGPIE_CONFIG_DIR=str(self.base / "magpie"),
                        XDG_DATA_HOME=str(self.base / "xdg #?%数据"),
                        CODEX_HOME=str(self.base / "codex"),
                        CLAUDE_CONFIG_DIR=str(self.base / "claude"),
                        PI_CODING_AGENT_DIR=str(self.base / "pi"))
        self.gemini = Path(self.env["GEMINI_CLI_HOME"])
        self.opencode = Path(self.env["XDG_DATA_HOME"]) / "opencode"
        self.magpie = Path(self.env["MAGPIE_CONFIG_DIR"])

    def swift(self, excluding=()):
        result = subprocess.run([str(self.binary), str(self.base / "cache.json")] + list(excluding),
                                env=self.env, check=True, text=True, capture_output=True)
        envelope = json.loads(result.stdout)
        self.last_diagnostics = envelope["diagnostics"]
        buckets = envelope["buckets"]
        flat = []
        for bucket in buckets:
            tokens = bucket.pop("tokens")
            bucket.update(tokens)
            flat.append(bucket)
        return flat

    def python(self, excluding=()):
        with contextlib.redirect_stderr(io.StringIO()):
            return (remote.collect_gemini(str(self.gemini)) + remote.collect_opencode(str(self.opencode))
                    + remote.collect_magpie(str(self.magpie), excluding))

    def check_totals(self, expected, excluding=()):
        for language, buckets in (("Python", self.python(excluding)), ("Swift", self.swift(excluding)),
                                  ("Swift warm", self.swift(excluding))):
            totals = {}
            for b in buckets:
                totals[b["cli"]] = totals.get(b["cli"], 0) + sum(b.get(k, 0) for k in TOKEN_FIELDS)
            self.assertEqual(totals, expected, language)

    def db(self, messages, wal=False):
        self.opencode.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.opencode / "opencode.db")
        if wal:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
        connection.execute("CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, data TEXT)")
        connection.executemany("INSERT OR REPLACE INTO message VALUES (?, ?)",
                               [(obj["id"], json.dumps(obj)) for obj in messages])
        connection.commit()
        self.addCleanup(connection.close)
        return connection

    def gateway(self, rows):
        self.magpie.mkdir(parents=True, exist_ok=True)
        (self.magpie / "usage.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))

    def test_gemini_cache_thoughts_copies_and_scoped_old_ids(self):
        message = {"id": "8065833f-2569-43ef-a30f-3fbec832da7a", "timestamp": "2025-12-08T07:25:58.127Z",
                   "type": "gemini", "model": "gemini-3-pro-preview",
                   "tokens": {"input": 49120, "output": 632, "cached": 3758, "thoughts": 1888, "total": 51640}}
        source = {"sessionId": "s1", "messages": [message, dict(message, id="1")]}
        write_json(self.gemini / "tmp/p1/chats/session-one.json", source)
        write_json(self.gemini / "tmp/p1/chats/session-copy.json", source)
        write_json(self.gemini / "tmp/p2/chats/session-two.json", {"sessionId": "s2", "messages": [dict(message, id="1")]})
        self.check_totals({"gemini": 51640 * 3})
        for buckets in (self.python(), self.swift()):
            self.assertTrue(all(b["provider"] == "google" for b in buckets))
            self.assertEqual(sum(b["output"] for b in buckets), 2520 * 3)
            self.assertTrue(all(b["day"] == "2025-12-08" for b in buckets))

    def test_opencode_total_decides_reasoning_and_mixed_migration(self):
        openai = open_message("one")  # reasoning already part of output
        anthropic = open_message("two", provider="anthropic")  # additive without total
        decisive = open_message("three", provider="custom")
        decisive["tokens"]["total"] = 165  # reasoning subset even on custom route
        additive = open_message("four")
        additive["tokens"]["total"] = 175  # total says reasoning additive even with OpenAI route
        self.db([openai, anthropic, decisive, additive, open_message("user", role="user")])
        for obj in [openai, anthropic, decisive, additive]:
            write_json(self.opencode / ("storage/message/s/" + obj["id"] + ".json"), obj)
            write_json(self.opencode / ("storage/message/copy/" + obj["id"] + ".json"), obj)
        self.check_totals({"opencode": 165 + 175 + 165 + 175})

    def test_cost_zero_unknown_free_route_positive_cost_and_1h(self):
        unknown = open_message("zero-unknown")
        free = open_message("free", modelID="fixture:free")
        paid = open_message("paid", cost=0.4)
        paid["tokens"]["cache"]["write1h"] = 7
        paid2 = open_message("paid-2", cost=0.6)
        self.db([unknown, free, paid, paid2])
        self.check_totals({"opencode": 165 * 4 + 7})
        for buckets in (self.python(), self.swift()):
            self.assertEqual(sum(b.get("reportedCostUSD") or 0 for b in buckets), 1.0)
            zero = [b for b in buckets if b.get("reportedCostUSD") == 0]
            self.assertEqual(len(zero), 1)
            self.assertEqual(zero[0]["model"], "fixture:free")
            self.assertEqual(sum(b.get("cacheWrite1h", 0) for b in buckets), 7)

    def test_magpie_mirrors_ambiguous_and_standalone_dedup(self):
        standalone = magpie_message()
        self.gateway([standalone, standalone, magpie_message("pi-mirror", agent="pi"),
                      magpie_message("unknown", agent="unknown"),
                      magpie_message("no-model", served=None, model=None)])
        self.check_totals({"magpie": 138})
        self.check_totals({}, excluding=("request:request-gateway-one",))
        # Exclusions must be re-evaluated on cache hits, not memoized as totals.
        self.check_totals({"magpie": 138})

    def test_magpie_real_schema_own_calls_fingerprint_and_diagnostics(self):
        own = {"t": "2026-09-30T14:12:10.391361+08:00", "agent": "magpie",
               "provider": "fixture", "model": "classifier", "req": "fixture/classifier",
               "served": "classifier", "in": 100, "out": 2, "status": 200}
        self.gateway([own, own, dict(own, agent="pi"), dict(own, t="2026-09-30T14:12:11.391361+08:00")])
        self.check_totals({"magpie": 204})
        stats = {}
        with contextlib.redirect_stderr(io.StringIO()):
            remote.collect_magpie(str(self.magpie), diagnostics=stats)
        self.assertEqual(stats["ambiguous"], 1)
        self.assertEqual(stats["duplicates"], 1)
        self.assertEqual(stats["standalone"], 2)
        self.swift()
        self.assertEqual(self.last_diagnostics["ambiguousMirrors"], 1)
        self.assertEqual(self.last_diagnostics["duplicateRecords"], 1)
        self.assertEqual(self.last_diagnostics["standaloneCalls"], 2)

    def test_disappeared_files_retained_across_persisted_cache(self):
        obj = open_message("legacy")
        path = self.opencode / "storage/message/s/legacy.json"
        write_json(path, obj)
        gemini_path = self.gemini / "tmp/project/chats/session-one.json"
        write_json(gemini_path, {"sessionId": "retained", "messages": [{
            "id": "one", "timestamp": "2026-10-01T00:00:00Z", "type": "gemini",
            "model": "fixture-gemini", "tokens": {"input": 100, "output": 20}}]})
        self.gateway([magpie_message()])
        self.assertEqual(sum(b["input"] for b in self.swift()), 300)
        path.unlink()
        gemini_path.unlink()
        (self.magpie / "usage.jsonl").unlink()
        self.assertEqual(sum(b["input"] for b in self.swift()), 300)
        self.assertEqual(sum(b["input"] for b in self.swift()), 300)

    def test_sqlite_wal_change_invalidates_event_cache(self):
        connection = self.db([open_message("first")], wal=True)
        self.check_totals({"opencode": 165})
        path = self.opencode / "opencode.db"
        signature = (path.stat().st_size, path.stat().st_mtime_ns)
        second = open_message("second")
        connection.execute("INSERT INTO message VALUES (?, ?)", (second["id"], json.dumps(second)))
        connection.commit()
        self.assertEqual(signature, (path.stat().st_size, path.stat().st_mtime_ns))
        self.check_totals({"opencode": 330})

    def test_remote_emit_preserves_provenance_and_sums_cost(self):
        buckets = [remote.additional_bucket("opencode", "m", "2026-10-01", (1, 2, 3, 4, 5), "p", 0.2),
                   remote.additional_bucket("opencode", "m", "2026-10-01", (1, 2, 3, 4, 5), "p", 0.3),
                   remote.additional_bucket("opencode", "m", "2026-10-01", (1, 2, 3, 4, 5), "other")]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            remote.emit(buckets)
        merged = json.loads(output.getvalue())["buckets"]
        self.assertEqual(len(merged), 2)
        reported = next(b for b in merged if b["provider"] == "p")
        self.assertEqual(reported["reportedCostUSD"], 0.5)
        self.assertEqual(reported["cacheWrite1h"], 10)

    def test_remote_main_uses_overrides_without_live_roots(self):
        self.db([open_message("isolated")])
        script = ROOT / "Sources/TokenBar/Resources/remote_collect.py"
        result = subprocess.run(["python3", str(script)], env=self.env, check=True, text=True, capture_output=True)
        envelope = json.loads(result.stdout)
        buckets = envelope["buckets"]
        self.assertEqual(sum(sum(b.get(k, 0) for k in TOKEN_FIELDS) for b in buckets), 165)
        self.assertEqual({b["cli"] for b in buckets}, {"opencode"})
        self.assertEqual(envelope["diagnostics"], [])

    def test_remote_envelope_missing_codex_and_magpie_diagnostics_readonly(self):
        codex = self.base / "codex #?%数据"
        codex.mkdir()
        self.env["CODEX_HOME"] = str(codex)
        present = codex / "present.jsonl"
        present.write_text("")
        db_path = codex / "state_5.sqlite"
        with sqlite3.connect(db_path) as connection:
            connection.execute("CREATE TABLE threads (rollout_path TEXT)")
            connection.executemany("INSERT INTO threads VALUES (?)", [
                (str(present),), (str(codex / "missing-one.jsonl"),),
                (str(codex / "missing-two.jsonl"),), (None,), ("",)])
        before = (db_path.read_bytes(), db_path.stat().st_mtime_ns)
        self.gateway([magpie_message("mirror", agent="pi")])
        with (self.magpie / "usage.jsonl").open("a") as handle:
            handle.write("{malformed\n")
        script = ROOT / "Sources/TokenBar/Resources/remote_collect.py"
        result = subprocess.run(["python3", str(script)], env=self.env, check=True, text=True, capture_output=True)
        envelope = json.loads(result.stdout)
        diagnostics = envelope["diagnostics"]
        self.assertEqual(envelope["buckets"], [])
        self.assertEqual(len(diagnostics), 3)
        self.assertTrue(any("Codex" in d and "2" in d for d in diagnostics))
        self.assertTrue(any("Magpie" in d and "镜像" in d and "1" in d for d in diagnostics))
        self.assertTrue(any("Magpie" in d and "解析" in d and "1" in d for d in diagnostics))
        self.assertNotIn(str(self.base), result.stdout)
        self.assertEqual(before, (db_path.read_bytes(), db_path.stat().st_mtime_ns))


if __name__ == "__main__":
    unittest.main(verbosity=2)
