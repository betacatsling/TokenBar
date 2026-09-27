#!/usr/bin/env python3
"""
Remote token aggregation for TokenBar.

Piped to `python3 -` on the remote host over SSH. Emits a small JSON envelope of
pre-aggregated buckets so raw transcripts never cross the network.

Targets Python 3.8 (the interpreter on server1) — no walrus-heavy idioms, no
match statements, no f-string `=`.

Mirrors the logic in the Swift collectors exactly; any change here must be
mirrored there. The rules that matter for correctness, each documented at
length in the collector it belongs to:

  * Claude Code rows are progressive streaming snapshots of one message, so
    dedupe by `message.id:requestId` taking the element-wise max — across
    files, because `--resume`/`--fork-session` copy the parent's rows into
    the new transcript verbatim. `journal.jsonl` under `subagents/` is
    workflow metadata, not usage.
  * Codex usage is a lineage over cumulative `total_token_usage` snapshots:
    gate on the lineage peak, charge `min(last, cumulative advance)`, treat
    `last == 0` rows as watermark-only, and tell counter restarts
    (`last == total` on a drop) from stale regressions. A forked rollout
    replays its parent's history, so its watermarks start at the parent's
    historical maximum. `sessions/` and `archived_sessions/` hold the same
    rollouts, deduplicated by file name.
  * Devin's `message_nodes` is a DAG that re-materialises each message once
    per following turn, so rows are de-duplicated by `request_id` (falling
    back to `message_id`), the model comes from `metadata.generation_model`,
    and the day from `metadata.created_at` — not the row stamp.
  * pi rows dedup across files on `responseId` — subagent artifacts and
    session forks copy rows verbatim — and attribute to `responseModel`
    (what the gateway served) rather than `model` (what was requested).
"""

import glob
import itertools
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")

# Trims a sub-second field to 6 digits: Python 3.8's fromisoformat takes exactly
# 3 or 6, and Devin writes 9 on server1.
_SUBSECOND_RE = re.compile(r"(\.\d{6})\d+")


def local_day(iso_str):
    """ISO-8601 timestamp -> local yyyy-MM-dd, or None.

    Devin writes nanosecond precision on server1
    ("2026-09-12T10:40:29.383418442Z"), which `fromisoformat` rejects outright on
    Python 3.8 -- it accepts 3 or 6 fractional digits and nothing else. Without
    the truncation below, 13,034 of server1's 13,046 timestamps fail to parse and
    silently fall back to the row stamp, which is exactly the bug this field
    exists to fix.
    """
    if not isinstance(iso_str, str) or not iso_str:
        return None
    try:
        s = iso_str.replace("Z", "+00:00")
        s = _SUBSECOND_RE.sub(r"\1", s)
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone().strftime("%Y-%m-%d")
    except (ValueError, AttributeError):
        return None


def day_from_unix(seconds):
    try:
        return datetime.fromtimestamp(float(seconds)).strftime("%Y-%m-%d")
    except (ValueError, OSError, TypeError):
        return datetime.now().strftime("%Y-%m-%d")


def today():
    return datetime.now().strftime("%Y-%m-%d")


def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def str_field(d, *keys):
    """First value among `keys` that is a string — Swift's `as? String` chain.

    An empty string counts as present (matching `as? String ??`), so callers
    that require non-empty must check the result themselves.
    """
    for key in keys:
        value = d.get(key)
        if isinstance(value, str):
            return value
    return None


def read_lines(path, start=0):
    """Yield decoded lines, tolerating malformed UTF-8."""
    try:
        with open(path, "rb") as handle:
            if start:
                handle.seek(start)
                handle.readline()  # discard the partial line
            for raw in handle:
                yield raw.decode("utf-8", "replace")
    except (OSError, IOError):
        return


def walk_jsonl(root):
    if not os.path.isdir(root):
        return []
    return glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)


def emit(buckets):
    """Merge and write the envelope."""
    merged = {}
    for b in buckets:
        key = (b["cli"], b["model"], b["day"], b["sidechain"])
        if key not in merged:
            merged[key] = b
        else:
            for field in ("input", "output", "cacheRead", "cacheWrite"):
                merged[key][field] += b[field]
    rows = list(merged.values())
    json.dump(
        {
            "version": 1,
            "host": os.uname()[1],
            "buckets": rows,
        },
        sys.stdout,
    )


# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------

def is_workflow_journal(path):
    """`.../<session>/subagents/**/journal.jsonl` — orchestration metadata,
    not a message transcript."""
    if os.path.basename(path) != "journal.jsonl":
        return False
    component = os.path.dirname(path)
    while len(component) > 1:
        if os.path.basename(component) == "subagents":
            return True
        parent = os.path.dirname(component)
        if parent == component:
            break
        component = parent
    return False


def collect_claude(root):
    """Claude Code transcripts, deduped per record across files.

    The transcript contains progressive streaming snapshots of the same
    assistant message, merged by per-field max under a composite key. The dedup
    map is global, not per file: `--resume` and `--fork-session` write a new
    transcript containing the parent's rows verbatim, and the copies carry
    identical composite keys, so the same merge collapses them rather than
    billing the replayed history again.
    """
    # Composite key -> [slot, counts]. Slot is (model, day, sidechain) of the
    # first occurrence — copies share it verbatim — and counts the running
    # per-field maximum.
    best = {}
    anon = itertools.count()
    for path in sorted(p for p in walk_jsonl(root) if not is_workflow_journal(p)):
        for line in read_lines(path):
            if '"usage"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "assistant":
                continue
            message = obj.get("message") or {}
            usage = message.get("usage") if isinstance(message, dict) else None
            if not isinstance(usage, dict):
                continue

            counts = (
                as_int(usage.get("input_tokens")),
                as_int(usage.get("output_tokens")),
                as_int(usage.get("cache_read_input_tokens")),
                as_int(usage.get("cache_creation_input_tokens")),
            )
            if sum(counts) <= 0:
                continue

            model = str_field(message, "model")
            if model is None:
                model = "unknown"
            # Synthetic entries are local bookkeeping, not real API calls.
            if model == "<synthetic>":
                continue

            day = local_day(obj.get("timestamp")) or today()
            sidechain = bool(obj.get("isSidechain"))
            slot = (model, day, sidechain)

            # tokscale's composite: a request retried under the same message id
            # must not merge into the first call. Rows lacking both ids fall
            # back to `uuid`, which copies also preserve.
            mid = message.get("id")
            if isinstance(mid, str):
                rid = obj.get("requestId")
                key = ("%s:%s" % (mid, rid)
                       if isinstance(rid, str) and rid
                       else "message:%s" % mid)
            else:
                uuid = obj.get("uuid")
                key = "uuid:%s" % (uuid if isinstance(uuid, str)
                                   else "anon-%d" % next(anon))

            entry = best.get(key)
            if entry is None:
                best[key] = [slot, counts]
            else:
                entry[1] = tuple(max(a, b) for a, b in zip(entry[1], counts))

    out = []
    for slot, counts in best.values():
        model, day, sidechain = slot
        out.append(
            {
                "cli": "claude-code",
                "model": model,
                "day": day,
                "input": counts[0],
                "output": counts[1],
                "cacheRead": counts[2],
                "cacheWrite": counts[3],
                "sidechain": sidechain,
            }
        )
    return out


# ---------------------------------------------------------------------------
# Codex — cumulative lineage
# ---------------------------------------------------------------------------

# The four cumulative counters Codex reports per `token_count` event, as a
# (input, cached, output, reasoning) tuple. `cached` is a subset of `input` and
# `reasoning` a subset of `output`, so the session-cumulative scalar is
# `input + output` — never the field sum.

ZERO_VEC = (0, 0, 0, 0)


def usage_vec(raw):
    """Decode a usage object into the 4-component cumulative vector.

    Accepts the two spellings Codex has used for the cached subset, and falls
    back to `total_tokens` alone when the components are absent (degraded rows
    still carry a scalar total).
    """
    if not isinstance(raw, dict):
        return None
    if "input_tokens" in raw or "output_tokens" in raw:
        return (
            as_int(raw.get("input_tokens")),
            max(as_int(raw.get("cached_input_tokens")),
                as_int(raw.get("cache_read_input_tokens"))),
            as_int(raw.get("output_tokens")),
            as_int(raw.get("reasoning_output_tokens")),
        )
    if "total_tokens" in raw:
        return (as_int(raw.get("total_tokens")), 0, 0, 0)
    return None


def vec_total(v):
    """Cumulative scalar: input + output. The subsets must not be added again."""
    return v[0] + v[2]


def vec_add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3])


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3])


def vec_max(a, b):
    return (max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def vec_clamped(v):
    """Clamp negative components to 0 and subsets to their parents. Deltas
    taken against a per-component peak can regress on a single component, and
    a malformed row can claim more cached than input."""
    i = max(0, v[0])
    o = max(0, v[2])
    return (i, min(max(0, v[1]), i), o, min(max(0, v[3]), o))


def vec_bounded(v, cap):
    """Bound `total` to `cap` by trimming the billable components. A fallback
    diff `total - peak` can claim more than the scalar advance when one
    component regressed while another advanced; the cumulative scalar is the
    honest bound, so excess is cut from input first (the largest, least
    precise bucket) then output."""
    if vec_total(v) <= cap:
        return v
    i, c, o, r = v
    excess = vec_total(v) - cap
    cut = min(excess, i)
    i -= cut
    c = min(c, i)
    excess -= cut
    if excess > 0:
        cut = min(excess, o)
        o -= cut
        r = min(r, o)
    return (i, c, o, r)


def codex_advance(state, total, last):
    """Fold one `token_count` snapshot into `state`, returning the component
    delta to charge (clamped, `total > 0`), or None when the event adds no new
    usage.

    Adapted from usageBar's `CodexLineage`; see the Swift `CodexLineage` for
    the measured rules:

    1. Peak gate — a snapshot at or below the lineage peak charges nothing.
    2. `min(last, advance)` — `last` is trusted only as a bounded increment;
       inflated writes fall back to the component diff, capped by the scalar
       advance.
    3. `last == 0` with a positive cumulative is an inherited/summary snapshot:
       it lifts the watermarks but is never charged.
    4. A cumulative drop restarts the counter only when `last == total`.
    5. Any other drop is a stale/out-of-order write, skipped without state.
    """
    if vec_total(total) <= 0:
        return None
    state["max_total"] = vec_max(state["max_total"], total)

    if last is None or vec_total(last) <= 0:
        state["peak"] = vec_max(state["peak"], total)
        state["peak_total"] = max(state["peak_total"], vec_total(total))
        state["prev_total"] = vec_total(total)
        return None

    prev = state["prev_total"]
    if prev is not None and vec_total(total) < prev:
        if vec_total(last) == vec_total(total):
            # Restarted counter: the new cumulative IS this turn's usage, so
            # reset watermarks and let the emit branch charge it.
            state["peak"] = ZERO_VEC
            state["peak_total"] = 0
        else:
            # Stale write.
            return None
    state["prev_total"] = vec_total(total)

    if vec_total(total) > state["peak_total"]:
        advance = vec_total(total) - state["peak_total"]
        if vec_total(last) <= advance:
            delta = last
        else:
            delta = vec_bounded(vec_sub(total, state["peak"]), advance)
        delta = vec_clamped(delta)
        state["peak_total"] = vec_total(total)
        state["peak"] = vec_max(state["peak"], total)
        return delta if vec_total(delta) > 0 else None

    state["peak"] = vec_max(state["peak"], total)
    return None


def session_meta(payload):
    """Identity from a `session_meta` payload.

    `payload.source` is a plain string in ordinary rollouts ("vscode") and an
    object in subagent ones, so it must be type-checked before reading through
    it.
    """
    source = payload.get("source")
    subagent = source.get("subagent") if isinstance(source, dict) else None
    if not isinstance(subagent, dict):
        subagent = None
    spawn = subagent.get("thread_spawn") if subagent else None
    parent = spawn.get("parent_thread_id") if isinstance(spawn, dict) else None

    own = str_field(payload, "id", "session_id") or ""
    forked = payload.get("forked_from_id")
    if not isinstance(forked, str):
        forked = parent if isinstance(parent, str) else None
    thread_source = payload.get("thread_source")
    return {
        "own_id": own,
        "forked_from": forked,
        "is_subagent": (subagent is not None
                        or thread_source == "subagent"
                        or thread_source == "guardian_review"),
    }


def probe_meta(path):
    """Just enough of the head to find the file's own `session_meta`.

    Fork decisions must be made before the scan, and the meta is always among
    the first lines, so this never touches the bulk of a rollout.
    """
    read = 0
    for line in read_lines(path):
        read += len(line.encode("utf-8", "replace")) + 1
        if '"session_meta"' in line:
            try:
                obj = json.loads(line)
            except ValueError:
                obj = None
            if isinstance(obj, dict) and obj.get("type") == "session_meta":
                payload = obj.get("payload")
                if isinstance(payload, dict):
                    return session_meta(payload)
        if read >= 256 * 1024:
            break
    return None


def rollout_files(roots):
    """`rollout-*.jsonl` under both roots, deduplicated by basename and sorted
    by basename so a parent is always processed before its forks (filenames
    embed an ISO timestamp, so lexical order is birth order)."""
    best = {}  # name -> (mtime, size, is_archived, path)
    for index, root in enumerate(roots):
        for path in walk_jsonl(root):
            name = os.path.basename(path)
            if not name.startswith("rollout-"):
                continue
            try:
                st = os.stat(path)
                mtime, size = st.st_mtime, st.st_size
            except OSError:
                mtime, size = 0.0, 0
            is_archived = index > 0
            existing = best.get(name)
            if existing is not None:
                # A file moved sessions->archived keeps its name; keep the
                # newer/bigger copy, preferring the active directory on a tie.
                better = (mtime > existing[0]
                          or (mtime == existing[0]
                              and (size > existing[1]
                                   or (size == existing[1] and not is_archived))))
                if not better:
                    continue
            best[name] = (mtime, size, is_archived, path)
    return [best[name][3] for name in sorted(best)]


def collect_codex(roots):
    """Codex rollouts, as a lineage over cumulative `total_token_usage` snapshots.

    Whole files are parsed in filename order so a parent is reduced before any
    fork that might inherit its watermark.
    """
    out = []
    # session id -> that rollout's historical max cumulative. A fork looks its
    # parent up here to start its watermarks past the replayed history.
    session_final = {}

    for path in rollout_files(roots):
        meta = probe_meta(path)
        # A fork should start from the parent's historical max — unless it is a
        # subagent thread: subagent usage is not part of the parent's
        # accounting, so subtracting it would zero the whole file.
        baseline = None
        if meta is not None and not meta["is_subagent"] and meta["forked_from"]:
            final = session_final.get(meta["forked_from"])
            if final is not None and vec_total(final) > 0:
                baseline = final

        state = {
            "model": "",
            "saw_meta": False,
            "session_id": "",
            "is_subagent": False,
            "peak": ZERO_VEC,
            "peak_total": 0,
            "prev_total": None,
            "max_total": ZERO_VEC,
        }
        if baseline is not None:
            # Prime the watermarks at the parent's historical maximum; events
            # at or below it are the replayed parent history and charge nothing.
            state["peak"] = baseline
            state["peak_total"] = vec_total(baseline)
            state["max_total"] = baseline

        acc = {}
        for line in read_lines(path):
            if ('"token_count"' not in line
                    and '"turn_context"' not in line
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
                # Only the first meta describes this file's own session. A
                # forked rollout repeats its ancestors' metas right after it,
                # and letting those through would reassign every later record
                # to an ancestor.
                if state["saw_meta"]:
                    continue
                state["saw_meta"] = True
                sm = session_meta(payload)
                state["session_id"] = sm["own_id"]
                state["is_subagent"] = sm["is_subagent"]
                continue

            if kind == "turn_context":
                m = payload.get("model")
                if isinstance(m, str) and m:
                    state["model"] = m
                continue

            if payload.get("type") != "token_count":
                continue
            info = payload.get("info")
            if not isinstance(info, dict):
                continue

            total = usage_vec(info.get("total_token_usage"))
            last = usage_vec(info.get("last_token_usage"))
            if total is None:
                if last is None or vec_total(last) <= 0:
                    continue
                # Rows without a cumulative (legacy/foreign writers) synthesize
                # one from the running peak so the normal lineage path handles
                # them.
                total = vec_add(state["peak"], last)

            delta = codex_advance(state, total, last)
            if delta is None:
                continue

            # `input` already includes `cached`; split so the buckets stay
            # meaningful. Codex reports no cache-creation counter.
            counts = (delta[0] - delta[1], delta[2], delta[1], 0)
            if sum(counts) <= 0:
                continue

            # `token_count` carries no model of its own: prefer a per-event
            # model when present, else the model carried forward from
            # `turn_context`. Usage seen before any model is attributed to
            # `unknown` rather than dropped — the tokens are real regardless
            # of labelling.
            model = str_field(payload, "model")
            if model is None:
                model = str_field(info, "model", "model_name")
            if model is None:
                model = state["model"] or "unknown"

            # The delta carries its own timestamp, so usage lands on the day it
            # actually happened. Subagent threads are normal usage:
            # `is_subagent` steers only the fork-baseline decision, not the
            # sidechain flag (see the Swift collector).
            day = local_day(obj.get("timestamp")) or today()
            key = (model, day)
            if key in acc:
                acc[key] = tuple(a + b for a, b in zip(acc[key], counts))
            else:
                acc[key] = counts

        for (model, day), counts in acc.items():
            out.append(
                {
                    "cli": "codex",
                    "model": model,
                    "day": day,
                    "input": counts[0],
                    "output": counts[1],
                    "cacheRead": counts[2],
                    "cacheWrite": counts[3],
                    "sidechain": False,
                }
            )

        sid = state["session_id"]
        if sid:
            existing = session_final.get(sid)
            session_final[sid] = (vec_max(existing, state["max_total"])
                                  if existing is not None
                                  else state["max_total"])
    return out


# ---------------------------------------------------------------------------
# pi
# ---------------------------------------------------------------------------

def collect_pi(root):
    """pi transcripts, deduped per record across files.

    pi transcripts get *copied*: an async/worker run mirrors its assistant rows
    into `subagent-artifacts/*_transcript.jsonl`, and session forks copy
    history verbatim — same `responseId`, same usage. Dedup is keyed on the
    globally stable `responseId`, with fallbacks for rows that lack one:

      * `r:<responseId>` — the gateway's id for the served response; copies
        share it.
      * `e:<entry id>:<usage sig>` — pi entry ids are copied verbatim, and
        folding the usage in guards against collisions between different rows
        that happen to share an 8-hex entry id. The timestamp is deliberately
        excluded — measured copies re-stamp it.
      * `s:<model>:<timestamp>:<usage sig>` — last resort for rows with
        neither id; it can merge independent identical calls, but anything
        weaker keys nothing and silently drops the row.

    What dedup deliberately does NOT do is merge rows by identical usage
    counts alone — two distinct calls can cost the same tokens.
    """
    seen = set()
    acc = {}
    # Sorted so the winner of a duplicated rid is deterministic. First
    # occurrence wins; measured copies carry byte-identical usage, so the
    # choice only fixes which timestamp family the day comes from.
    for path in sorted(walk_jsonl(os.path.join(root, "sessions"))):
        session_model = None
        for line in read_lines(path):
            if '"usage"' in line:
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                message = obj.get("message") or {}
                usage = message.get("usage") if isinstance(message, dict) else None
                if not isinstance(usage, dict):
                    continue
                counts = (
                    as_int(usage.get("input")),
                    as_int(usage.get("output")),
                    as_int(usage.get("cacheRead")),
                    # `cacheWrite1h` is the extended-TTL tier, billed separately
                    # but still cache-creation tokens.
                    as_int(usage.get("cacheWrite"))
                    + as_int(usage.get("cacheWrite1h")),
                )
                if sum(counts) <= 0:
                    continue
                # `responseModel` is what the gateway actually served; `model`
                # is only what was requested, and pi's proxies substitute
                # freely.
                model = str_field(message, "responseModel", "modelId",
                                  "model", "provider")
                if model is None:
                    model = session_model or "unknown"
                day = local_day(obj.get("timestamp")) or today()
                ts_str = obj.get("timestamp")
                if not isinstance(ts_str, str):
                    ts_str = ""

                sig = "/".join(str(c) for c in counts)
                response_id = message.get("responseId")
                entry_id = obj.get("id")
                if isinstance(response_id, str) and response_id:
                    rid = "r:%s" % response_id
                elif isinstance(entry_id, str) and entry_id:
                    rid = "e:%s:%s" % (entry_id, sig)
                else:
                    rid = "s:%s:%s:%s" % (model, ts_str, sig)
                if rid in seen:
                    continue
                seen.add(rid)

                key = (model, day)
                if key in acc:
                    acc[key] = tuple(a + b for a, b in zip(acc[key], counts))
                else:
                    acc[key] = counts
            elif '"model_change"' in line:
                # model_change carries the model for the whole session.
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                m = obj.get("modelId")
                if isinstance(m, str) and m:
                    session_model = m

    out = []
    for (model, day), counts in acc.items():
        out.append(
            {
                "cli": "pi",
                "model": model,
                "day": day,
                "input": counts[0],
                "output": counts[1],
                "cacheRead": counts[2],
                "cacheWrite": counts[3],
                "sidechain": False,
            }
        )
    return out


# ---------------------------------------------------------------------------
# Devin
# ---------------------------------------------------------------------------

def collect_devin(db_path):
    """Devin CLI usage from its SQLite store, opened read-only.

    `message_nodes` is a DAG: each turn re-materialises the whole conversation
    chain as fresh nodes, so one assistant message is stored once per following
    turn with identical metrics. `metadata.request_id` identifies the
    underlying API request and copies share it, so rows dedup by
    `(session_id, request_id)` with `message_id` as fallback — and a row with
    neither counts once, since dropping it would lose real usage.

    The model comes from `metadata.generation_model` — what served this
    particular call. `sessions.model` is only the session's current setting: it
    relabels every earlier call after a mid-session switch, and `adaptive` is a
    router alias, not a model.
    """
    if not os.path.exists(db_path):
        return []
    out = []
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    except sqlite3.Error:
        return []
    try:
        cursor = conn.execute(
            "SELECT s.model, m.chat_message, m.created_at, m.session_id "
            "FROM message_nodes m JOIN sessions s ON s.id = m.session_id "
            "ORDER BY m.row_id"
        )
        acc = {}
        seen = set()
        for session_model, chat_message, created_at, session_id in cursor:
            if not chat_message:
                continue
            try:
                obj = json.loads(chat_message)
            except ValueError:
                continue
            # Only assistant rows carry real usage — no usage-bearing
            # non-assistant row has been observed, but filter anyway so a
            # schema change can't bill user bookkeeping as model traffic.
            role = obj.get("role")
            if isinstance(role, str) and role != "assistant":
                continue
            metadata = obj.get("metadata")
            if not isinstance(metadata, dict):
                continue

            metrics = metadata.get("metrics")
            if isinstance(metrics, dict):
                counts = (
                    as_int(metrics.get("input_tokens")),
                    as_int(metrics.get("output_tokens")),
                    as_int(metrics.get("cache_read_tokens")),
                    as_int(metrics.get("cache_creation_tokens")),
                )
            else:
                counts = (0, 0, 0, 0)
            # Some schemas report `num_tokens` when no metrics block is
            # written; fold it into output rather than dropping the row.
            num_tokens = as_int(metadata.get("num_tokens"))
            if sum(counts) <= 0 and num_tokens > 0:
                counts = (0, num_tokens, 0, 0)
            if sum(counts) <= 0:
                continue

            request_id = metadata.get("request_id")
            message_id = obj.get("message_id")
            dedup = None
            if isinstance(request_id, str) and request_id:
                dedup = request_id
            elif isinstance(message_id, str) and message_id:
                dedup = message_id
            if dedup is not None:
                key = (session_id or "", dedup)
                if key in seen:
                    continue
                seen.add(key)

            served = metadata.get("generation_model")
            if not (isinstance(served, str) and served):
                served = (session_model
                          if session_model and session_model != "adaptive"
                          else "unknown")
            # `swe-2-high` / `swe-2-max` are effort tiers of one model, not two
            # models. Scoped to the swe-2- prefix on purpose: a generic
            # "strip -max" rule would also merge gpt-5.1-codex-max, which is a
            # distinct model with its own price.
            if served.lower().startswith("swe-2-"):
                served = "swe-2"
            # `metadata.created_at` is when the call happened; the row's
            # `created_at` is when this copy was materialised, which is the
            # time of a later turn (median +80 min locally, up to 24.7 h).
            day = (local_day(metadata.get("created_at"))
                   or day_from_unix(created_at))
            key = (served, day)
            if key in acc:
                acc[key] = tuple(a + b for a, b in zip(acc[key], counts))
            else:
                acc[key] = counts

        for (model, day), counts in acc.items():
            out.append(
                {
                    "cli": "devin",
                    "model": model,
                    "day": day,
                    "input": counts[0],
                    "output": counts[1],
                    "cacheRead": counts[2],
                    "cacheWrite": counts[3],
                    "sidechain": False,
                }
            )
    except sqlite3.Error:
        pass
    finally:
        conn.close()
    return out


def main():
    claude_config = os.environ.get("CLAUDE_CONFIG_DIR") \
        or os.path.join(HOME, ".claude")
    codex_home = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
    pi_dir = os.environ.get("PI_CODING_AGENT_DIR") \
        or os.path.join(HOME, ".pi", "agent")
    xdg_data = os.environ.get("XDG_DATA_HOME") \
        or os.path.join(HOME, ".local", "share")

    buckets = []
    buckets += collect_claude(os.path.join(claude_config, "projects"))
    buckets += collect_codex(
        [
            os.path.join(codex_home, "sessions"),
            os.path.join(codex_home, "archived_sessions"),
        ]
    )
    buckets += collect_pi(pi_dir)
    buckets += collect_devin(
        os.path.join(xdg_data, "devin", "cli", "sessions.db")
    )
    emit(buckets)


if __name__ == "__main__":
    main()
