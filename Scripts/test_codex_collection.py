#!/usr/bin/env python3
"""Synthetic accounting regressions, run against BOTH production collectors.

Build first with `swift build -c release`, then run this file. All logs and
collector roots are temporary; no real usage or app cache is modified.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "remote_collect", ROOT / "Sources/TokenBar/Resources/remote_collect.py")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
BINARY = Path(os.environ.get("TOKENBAR_BINARY", ROOT / ".build/release/TokenBar"))


def row(kind, payload):
    return {"timestamp": "2026-09-27T08:00:00Z", "type": kind, "payload": payload}


def usage(i=100, o=10, c=40):
    return {"input_tokens": i, "output_tokens": o, "cached_input_tokens": c}


def modern(response, counts=None, total=None, thread="child"):
    return row("token_usage_record", {
        "thread_id": thread, "response_id": response,
        "usage": counts or usage(), "thread_token_usage": total or usage()})


def legacy(total=None, last=None):
    return row("event_msg", {"type": "token_count", "info": {
        "total_token_usage": total or usage(), "last_token_usage": last or usage()}})


class CodexCollectionTests(unittest.TestCase):
    def check_collectors(self, events, expected, subagent=False, parent=None, fork=False,
                         remove_after_cold=None, append_after_cold=None, warm_expected=None,
                         expected_metadata=None):
        with tempfile.TemporaryDirectory(prefix="tokenbar-codex-test-") as tmp:
            base = Path(tmp)
            sessions = base / "sessions"
            sessions.mkdir()
            source = {"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}} if subagent else "vscode"
            header = [row("session_meta", {"id": "child", "source": source,
                                           **({"forked_from_id": "parent"} if fork else {})}),
                      row("turn_context", {"model": "gpt-6-luna"})]
            if parent is not None:
                # Deliberately sort the parent AFTER its child.
                (sessions / "rollout-z-parent.jsonl").write_text("".join(
                    json.dumps(e) + "\n" for e in [row("session_meta", {"id": "parent"}),
                    row("turn_context", {"model": "gpt-6-luna"})] + parent))
            (sessions / "rollout-child.jsonl").write_text(
                "".join(json.dumps(e) + "\n" for e in header + events))
            buckets = remote.collect_codex([str(sessions), str(base / "archived_sessions")])
            actual = {}
            for b in buckets:
                actual[b["model"]] = actual.get(b["model"], 0) + sum(
                    b[k] for k in ("input", "output", "cacheRead", "cacheWrite"))
                self.assertFalse(b["sidechain"])
                self.assertGreaterEqual(b["input"], 0)
            self.assertEqual(actual, expected, "remote Python collector")
            if expected_metadata is not None:
                self.assertCountEqual([(b.get("provider"), b.get("serviceTier"), b.get("speed"))
                                       for b in buckets], expected_metadata)
            env = dict(os.environ, CODEX_HOME=tmp, CLAUDE_CONFIG_DIR=tmp + "/claude",
                       PI_CODING_AGENT_DIR=tmp + "/pi", XDG_DATA_HOME=tmp + "/xdg",
                       GEMINI_CLI_HOME=tmp + "/gemini", MAGPIE_CONFIG_DIR=tmp + "/magpie",
                       TOKENBAR_VERIFY_CACHE=tmp + "/cache.json", TOKENBAR_BILLING_FILE=tmp + "/billing.json")
            # A cold pass followed by a persisted-cache pass must agree.
            for flags in ([], ["--warm"]):
                result = subprocess.run([str(BINARY), "--verify", "--models"] + flags,
                                        env=env, text=True, capture_output=True, check=True)
                actual = {}
                for line in result.stdout.splitlines():
                    if line.startswith("model."):
                        name, value = line[6:].rsplit(": ", 1)
                        actual[name] = int(value)
                self.assertEqual(actual, expected, "Swift collector " + str(flags))
                if not flags:
                    if remove_after_cold == "parent":
                        (sessions / "rollout-z-parent.jsonl").unlink()
                    elif remove_after_cold == "all":
                        for path in sessions.glob("*.jsonl"):
                            path.unlink()
                    if append_after_cold:
                        with (sessions / "rollout-child.jsonl").open("a") as stream:
                            stream.write("".join(json.dumps(e) + "\n" for e in append_after_cold))
                    if warm_expected is not None:
                        expected = warm_expected

    def test_modern_only_subagent_and_replayed_response(self):
        self.check_collectors([modern("a"), modern("a"), modern("b")],
                              {"gpt-6-luna": 220}, subagent=True)

    def test_dual_write_with_different_cumulative_offsets(self):
        self.check_collectors([modern("a"), legacy(usage(5100, 510, 2040)),
                               legacy(usage(5100, 510, 2040)),
                               modern("b", total=usage(200, 20, 80)),
                               legacy(usage(5200, 520, 2080))], {"gpt-6-luna": 220})

    def test_legacy_restart_after_modern_record(self):
        self.check_collectors([legacy(usage(5000, 500, 0), usage(5000, 500, 0)),
                               modern("a"), legacy(),
                               legacy(usage(200, 20, 80))], {"gpt-6-luna": 5720})

    def test_legacy_before_migration_and_after_modern(self):
        self.check_collectors([legacy(), modern("a", total=usage(200, 20, 80)),
                               legacy(usage(200, 20, 80)),
                               legacy(usage(250, 25, 80), usage(50, 5, 0))],
                              {"gpt-6-luna": 275})

    def test_model_change_and_unknown_price(self):
        self.check_collectors([modern("a"), legacy(),
                               row("turn_context", {"model": "future-unpriced-model"}),
                               modern("b", total=usage(200, 20, 80))],
                              {"gpt-6-luna": 110, "future-unpriced-model": 110})

    def test_new_turn_legacy_response_is_not_previous_turn_mirror(self):
        self.check_collectors([modern("a"),
                               row("turn_context", {"model": "gpt-6-sol"}), legacy()],
                              {"gpt-6-luna": 110, "gpt-6-sol": 110})

    def test_copied_ancestor_record_not_billed_to_child(self):
        self.check_collectors([modern("parent-response", thread="parent"), modern("own")],
                              {"gpt-6-luna": 110})

    def test_missing_response_id_falls_back_to_legacy(self):
        self.check_collectors([modern(""), legacy()], {"gpt-6-luna": 110})

    def test_malformed_and_empty_records(self):
        self.check_collectors([row("token_usage_record", {}),
                               modern("zero", usage(0, 0, 0)), modern("real")],
                              {"gpt-6-luna": 110})

    def test_parent_continues_after_fork(self):
        copied = legacy(usage(100, 0, 0), usage(100, 0, 0))
        self.check_collectors([copied, legacy(usage(200, 0, 0), usage(100, 0, 0))],
                              {"gpt-6-luna": 1100}, fork=True,
                              parent=[copied, legacy(usage(1000, 0, 0), usage(900, 0, 0))])

    def test_fork_copies_counter_reset_history(self):
        history = [legacy(usage(1000, 0, 0), usage(1000, 0, 0)),
                   legacy(usage(100, 0, 0), usage(100, 0, 0)),
                   legacy(usage(200, 0, 0), usage(100, 0, 0))]
        self.check_collectors(history + [legacy(usage(300, 0, 0), usage(100, 0, 0))],
                              {"gpt-6-luna": 1300}, fork=True, parent=history)

    def test_replayed_reset_in_same_session_is_not_rebilled(self):
        history = [legacy(usage(1000, 0, 0), usage(1000, 0, 0)),
                   legacy(usage(100, 0, 0), usage(100, 0, 0)),
                   legacy(usage(200, 0, 0), usage(100, 0, 0))]
        self.check_collectors(history + history + [legacy(usage(300, 0, 0), usage(100, 0, 0))],
                              {"gpt-6-luna": 1300})

    def test_component_regression_clamped_before_cap(self):
        self.check_collectors([legacy(usage(1000, 0, 0), usage(1000, 0, 0)),
                               legacy(usage(100, 1000, 0), usage(200, 0, 0))],
                              {"gpt-6-luna": 1100})

    def test_negative_last_components_are_bounded_after_clamp(self):
        self.check_collectors([legacy(usage(100, 0, 0), usage(-900, 1000, 0))],
                              {"gpt-6-luna": 100})

    def test_equal_usage_without_mirror_time_is_independent(self):
        independent = legacy()
        independent["timestamp"] = "2026-09-27T08:00:30Z"
        self.check_collectors([modern("a"), independent], {"gpt-6-luna": 220})

    def test_explicit_different_response_identity_is_independent(self):
        independent = legacy()
        independent["payload"]["info"]["response_id"] = "different"
        self.check_collectors([modern("a"), independent], {"gpt-6-luna": 220})

    def test_response_identity_dedups_independent_counter_offsets(self):
        first = legacy()
        first["payload"]["info"]["response_id"] = "same"
        second = legacy(usage(5000, 500, 0))
        second["payload"]["info"]["response_id"] = "same"
        self.check_collectors([first, second, modern("same")], {"gpt-6-luna": 110})

    def test_explicit_response_identity_mirrors_without_time_heuristic(self):
        mirror = legacy(usage(5000, 500, 0))
        mirror["timestamp"] = "2026-09-27T08:05:30Z"
        mirror["payload"]["info"]["response_id"] = "a"
        self.check_collectors([modern("a"), mirror], {"gpt-6-luna": 110})

    def test_modern_and_legacy_fork_copy(self):
        history = [modern("old", thread="parent"), legacy()]
        self.check_collectors(history + [modern("new", total=usage(200, 20, 80)),
                                        legacy(usage(200, 20, 80))],
                              {"gpt-6-luna": 220}, parent=history, fork=True)

    def test_missing_parent_does_not_zero_independent_usage(self):
        self.check_collectors([legacy()], {"gpt-6-luna": 110}, fork=True)

    def test_last_only_legacy_copy(self):
        copied = row("event_msg", {"type": "token_count", "info": {
            "last_token_usage": usage(100, 0, 0)}})
        own = row("event_msg", {"type": "token_count", "info": {
            "last_token_usage": usage(100, 0, 0)}})
        own["timestamp"] = "2026-09-27T08:01:00Z"
        self.check_collectors([copied, own], {"gpt-6-luna": 200}, parent=[copied], fork=True)

    def test_provider_and_modern_tier_metadata(self):
        priority = modern("priority")
        priority["payload"]["usage"]["service_tier"] = "priority"
        fast = modern("fast")
        fast["payload"]["speed"] = "fast"
        self.check_collectors([
            row("turn_context", {"model": "gpt-6-luna", "model_provider": "custom-gateway"}), priority,
            row("turn_context", {"model": "gpt-6-luna", "model_provider": "openai"}), fast],
            {"gpt-6-luna": 220},
            expected_metadata=[("custom-gateway", "priority", None), ("openai", None, "fast")])

    def test_retained_missing_parent_with_appended_child(self):
        history = [legacy(usage(1000, 0, 0), usage(1000, 0, 0)),
                   legacy(usage(100, 0, 0), usage(100, 0, 0)),
                   legacy(usage(200, 0, 0), usage(100, 0, 0))]
        self.check_collectors(history + [legacy(usage(300, 0, 0), usage(100, 0, 0))],
                              {"gpt-6-luna": 1300}, fork=True, parent=history,
                              remove_after_cold="parent",
                              append_after_cold=[legacy(usage(400, 0, 0), usage(100, 0, 0))],
                              warm_expected={"gpt-6-luna": 1400})

    def test_missing_fork_retains_corrected_buckets(self):
        copied = legacy(usage(100, 0, 0), usage(100, 0, 0))
        self.check_collectors([copied, legacy(usage(200, 0, 0), usage(100, 0, 0))],
                              {"gpt-6-luna": 1100}, fork=True,
                              parent=[copied, legacy(usage(1000, 0, 0), usage(900, 0, 0))],
                              remove_after_cold="all")


if __name__ == "__main__":
    unittest.main()
