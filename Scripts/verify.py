#!/usr/bin/env python3
"""
Independent cross-check for TokenBar.

Written deliberately as a separate implementation from the Swift collectors so
that agreement between the two is meaningful evidence rather than a shared bug.
Prints the same `key: value` lines as `tokenbar --verify`, so the two outputs can
be diffed directly.

Usage:
    python3 Scripts/verify.py            # local machine
    python3 Scripts/verify.py --naive    # also report the Claude dedup ratio

Exit code is non-zero if any collector fails outright.
"""

import argparse
import glob
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")


# ---------------------------------------------------------------- helpers

# Devin writes 9 fractional digits on server1; fromisoformat takes 3 or 6.
_SUBSECOND_RE = re.compile(r"(\.\d{6})\d+")


def local_day(iso_str):
    if not iso_str:
        return None
    try:
        dt = datetime.fromisoformat(
            _SUBSECOND_RE.sub(r"\1", iso_str.replace("Z", "+00:00")))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone().strftime("%Y-%m-%d")
    except (ValueError, AttributeError):
        return None


def today():
    return datetime.now().strftime("%Y-%m-%d")


def epoch_ms(iso_str):
    """ISO-8601 -> epoch milliseconds, for the fork-copy gap threshold."""
    if not iso_str:
        return None
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp() * 1000.0
    except (ValueError, AttributeError):
        return None


def walk(root):
    if not os.path.isdir(root):
        return []
    return glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)


def lines(path, start=0):
    try:
        with open(path, "rb") as handle:
            if start:
                handle.seek(start)
                handle.readline()
            for raw in handle:
                yield raw.decode("utf-8", "replace")
    except (OSError, IOError):
        return


# ---------------------------------------------------------------- collectors

def claude(include_sidechain):
    """Dedupe by message id with an element-wise max (streaming snapshots).

    A message is attributed to the day and sidechain flag of the *first* record
    seen for its key, then counted exactly once. `include_sidechain` filters the
    reported totals; the naive/deduped comparison deliberately counts everything
    so the two sides of that ratio describe the same population.
    """
    total = 0
    naive = 0
    deduped_all = 0
    per_cli = {}
    per_day = {}
    per_model = {}
    paths = walk(os.path.join(HOME, ".claude", "projects"))
    for path in paths:
        best = {}
        meta = {}
        for line in lines(path):
            if '"usage"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message") or {}
            usage = msg.get("usage") if isinstance(msg, dict) else None
            if not isinstance(usage, dict):
                continue
            if msg.get("model") == "<synthetic>":
                continue
            counts = (
                usage.get("input_tokens", 0) or 0,
                usage.get("output_tokens", 0) or 0,
                usage.get("cache_read_input_tokens", 0) or 0,
                usage.get("cache_creation_input_tokens", 0) or 0,
            )
            if sum(counts) <= 0:
                continue
            naive += sum(counts)

            key = msg.get("id") or obj.get("uuid") or str(id(obj))
            if key in best:
                best[key] = tuple(max(a, b) for a, b in zip(best[key], counts))
            else:
                best[key] = counts
                meta[key] = (local_day(obj.get("timestamp")) or today(),
                             bool(obj.get("isSidechain")),
                             msg.get("model") or "unknown")

        for key, counts in best.items():
            n = sum(counts)
            deduped_all += n
            day, sidechain, model = meta[key]
            if sidechain and not include_sidechain:
                continue
            total += n
            per_cli["claude-code"] = per_cli.get("claude-code", 0) + n
            per_model[model] = per_model.get(model, 0) + n
            per_day[day] = per_day.get(day, 0) + n

    return {"total": total, "files": len(paths), "per_cli": per_cli,
            "per_day": per_day, "per_model": per_model,
            "naive": naive, "deduped_all": deduped_all}


def codex():
    """Sum per-turn deltas, suppressing fork copies and duplicate re-emissions.

    Deliberately written from the on-disk format rather than ported from the
    Swift: the point of this script is to disagree when the Swift is wrong. The
    shape it must match is documented in CodexCollector -- reading the final
    ``total_token_usage`` from each file's tail instead loses model attribution
    on 101 of 476 files, double counts forked rollouts, and undercounts any
    session whose counter reset at a compaction.
    """
    FORK_COPY_MAX_GAP_MS = 1000
    total = 0
    files = 0
    per_cli = {}
    per_day = {}
    per_model = {}
    roots = [os.path.join(HOME, ".codex", "sessions"),
             os.path.join(HOME, ".codex", "archived_sessions")]

    def is_forked(payload):
        if isinstance(payload.get("forked_from_id"), str):
            return True
        # `source` is a plain string ("vscode") in ordinary rollouts and an
        # object only in forked ones, so it must be type-checked.
        source = payload.get("source")
        if not isinstance(source, dict):
            return False
        subagent = source.get("subagent")
        if not isinstance(subagent, dict):
            return False
        spawn = subagent.get("thread_spawn")
        if not isinstance(spawn, dict):
            return False
        return isinstance(spawn.get("parent_thread_id"), str)

    for root in roots:
        for path in walk(root):
            files += 1
            model = ""
            saw_meta = False
            suppressing = False
            anchor_ms = 0.0
            last_sig = None

            for line in lines(path):
                if ('"token_count"' not in line and '"turn_context"' not in line
                        and '"session_meta"' not in line):
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                payload = obj.get("payload")
                if not isinstance(payload, dict):
                    continue

                kind = obj.get("type")
                if kind == "session_meta":
                    # Only the first meta describes this file's own session; a
                    # forked rollout repeats its ancestors' metas right after.
                    if saw_meta:
                        continue
                    saw_meta = True
                    ms = epoch_ms(obj.get("timestamp"))
                    if ms is not None and is_forked(payload):
                        suppressing = True
                        anchor_ms = ms
                    continue
                if kind == "turn_context":
                    m = payload.get("model")
                    if isinstance(m, str) and m:
                        model = m
                    continue

                if payload.get("type") != "token_count":
                    continue
                info = payload.get("info")
                if not isinstance(info, dict):
                    continue
                last = info.get("last_token_usage")
                if not isinstance(last, dict):
                    continue
                # An event before its turn_context must not consume the dedup
                # signature, or the re-emission after the model is known would
                # be dropped as a duplicate.
                if not model:
                    continue
                ms = epoch_ms(obj.get("timestamp"))
                if ms is None:
                    continue

                sig = "/".join(str(last.get(k, 0) or 0) for k in (
                    "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                    "output_tokens", "reasoning_output_tokens"))
                if sig == last_sig:
                    continue
                last_sig = sig

                if suppressing:
                    if ms - anchor_ms < FORK_COPY_MAX_GAP_MS:
                        anchor_ms = ms
                        continue
                    suppressing = False

                raw_input = last.get("input_tokens", 0) or 0
                cached = last.get("cached_input_tokens", 0) or 0
                cache_write = last.get("cache_write_input_tokens", 0) or 0
                output = last.get("output_tokens", 0) or 0
                # input_tokens is inclusive of the cached slice.
                n = max(0, raw_input - cached - cache_write) + output + cached + cache_write
                if n <= 0:
                    continue
                total += n
                per_cli["codex"] = per_cli.get("codex", 0) + n
                per_model[model] = per_model.get(model, 0) + n
                d = local_day(obj.get("timestamp")) or today()
                per_day[d] = per_day.get(d, 0) + n
    return {"total": total, "files": files, "per_cli": per_cli, "per_day": per_day,
            "per_model": per_model}


def devin():
    """One row per stored node, but one *call* per message_id.

    message_nodes is a DAG: each turn re-materialises the whole chain, so an
    assistant message reappears once per following turn with identical metrics.
    Counting rows overcounts 2.485x on this machine.

    The model comes from metadata.generation_model (what served this call), not
    sessions.model (the session's current setting, which retroactively relabels
    earlier calls and is empty for sessions that never set one).
    """
    db = os.path.join(HOME, ".local", "share", "devin", "cli", "sessions.db")
    total = 0
    per_cli = {}
    per_day = {}
    per_model = {}
    if not os.path.exists(db):
        return {"total": 0, "files": 0, "per_cli": {}, "per_day": {}, "per_model": {}}
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    seen = set()
    try:
        for model, chat, created, session in conn.execute(
                "SELECT s.model, m.chat_message, m.created_at, m.session_id"
                " FROM message_nodes m JOIN sessions s ON s.id = m.session_id"
                " ORDER BY m.row_id"):
            if not chat:
                continue
            try:
                obj = json.loads(chat)
            except ValueError:
                continue
            metadata = obj.get("metadata") or {}
            metrics = metadata.get("metrics")
            if not isinstance(metrics, dict):
                continue
            n = (metrics.get("input_tokens", 0) or 0) \
                + (metrics.get("output_tokens", 0) or 0) \
                + (metrics.get("cache_read_tokens", 0) or 0) \
                + (metrics.get("cache_creation_tokens", 0) or 0)
            if n <= 0:
                continue
            message_id = obj.get("message_id")
            if isinstance(message_id, str) and message_id:
                key = (session, message_id)
                if key in seen:
                    continue
                seen.add(key)
            served = metadata.get("generation_model")
            name = served if isinstance(served, str) and served else (model or "unknown")
            # swe-2's -high/-max are effort tiers of one model, not two models.
            if name.lower().startswith("swe-2-"):
                name = "swe-2"
            total += n
            per_cli["devin"] = per_cli.get("devin", 0) + n
            per_model[name] = per_model.get(name, 0) + n
            # metadata.created_at is when the call happened; the row stamp is
            # when this copy was materialised by a later turn.
            d = local_day(metadata.get("created_at")) \
                or datetime.fromtimestamp(created).strftime("%Y-%m-%d")
            per_day[d] = per_day.get(d, 0) + n
    finally:
        conn.close()
    return {"total": total, "files": 1, "per_cli": per_cli, "per_day": per_day,
            "per_model": per_model}


def pi():
    total = 0
    per_cli = {}
    per_day = {}
    per_model = {}
    paths = walk(os.path.join(HOME, ".pi", "agent", "sessions"))
    for path in paths:
        for line in lines(path):
            if '"usage"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            msg = obj.get("message") or {}
            usage = msg.get("usage") if isinstance(msg, dict) else None
            if not isinstance(usage, dict):
                continue
            # cacheWrite1h is the extended-TTL cache tier; still cache creation.
            n = (usage.get("input", 0) or 0) + (usage.get("output", 0) or 0) \
                + (usage.get("cacheRead", 0) or 0) + (usage.get("cacheWrite", 0) or 0) \
                + (usage.get("cacheWrite1h", 0) or 0)
            if n <= 0:
                continue
            # responseModel is what the gateway served; `model` is only what
            # was requested, and pi's proxies substitute freely.
            name = (msg.get("responseModel") or msg.get("modelId")
                    or msg.get("model") or msg.get("provider") or "unknown")
            total += n
            per_cli["pi"] = per_cli.get("pi", 0) + n
            per_model[name] = per_model.get(name, 0) + n
            d = local_day(obj.get("timestamp")) or today()
            per_day[d] = per_day.get(d, 0) + n
    return {"total": total, "files": len(paths), "per_cli": per_cli, "per_day": per_day,
            "per_model": per_model}


# ---------------------------------------------------------------- main

def recent_days(count):
    """The last `count` days ending today, oldest first (matches Swift)."""
    today_dt = datetime.now().date()
    return [(today_dt.fromordinal(today_dt.toordinal() - offset)).strftime("%Y-%m-%d")
            for offset in range(count - 1, -1, -1)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--include-sidechain", action="store_true")
    parser.add_argument("--naive", action="store_true",
                        help="also report the Claude dedup ratio")
    parser.add_argument("--models", action="store_true",
                        help="also report per-model totals (model attribution is "
                             "invisible in the per-cli/per-day lines)")
    args = parser.parse_args()

    results = {
        "claude-code": claude(args.include_sidechain),
        "codex": codex(),
        "devin": devin(),
        "pi": pi(),
    }

    print("== TokenBar verify (python reference) ==")
    print("date: %s" % today())
    print("includeSidechain: %s" % args.include_sidechain)

    grand = 0
    per_cli = {}
    per_day = {}
    for name in ("claude-code", "codex", "devin", "pi"):
        r = results[name]
        # Same layout as `tokenbar --verify`: the per-collector line, the total,
        # and the per-cli lines must all describe the same sidechain-filtered set,
        # or the printed parts will not sum to the printed total.
        name_p = name.ljust(14)
        print("%s files=%-6d tokens=%-14d" % (name_p, r.get("files", 0), r["total"]))
        grand += r["total"]
        for k, v in r["per_cli"].items():
            per_cli[k] = per_cli.get(k, 0) + v
        for k, v in r["per_day"].items():
            per_day[k] = per_day.get(k, 0) + v

    print("----")
    print("total_tokens: %d" % grand)
    for k in sorted(per_cli):
        print("cli.%s: %d" % (k, per_cli[k]))

    for day in recent_days(14):
        print("day.%s: %d" % (day, per_day.get(day, 0)))

    if args.models:
        per_model = {}
        for name in ("claude-code", "codex", "devin", "pi"):
            for k, v in (results[name].get("per_model") or {}).items():
                per_model[k] = per_model.get(k, 0) + v
        if per_model:
            print("----")
            for k in sorted(per_model):
                print("model.%s: %d" % (k, per_model[k]))

    if args.naive:
        c = results["claude-code"]
        print("----")
        print("claude_naive_sum: %d" % c["naive"])
        print("claude_deduped: %d" % c["deduped_all"])
        if c["deduped_all"]:
            print("claude_naive_over_deduped_ratio: %.3f"
                  % (c["naive"] / c["deduped_all"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
