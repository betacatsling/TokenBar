#!/usr/bin/env python3
"""Show why Devin's `message_nodes` must be de-duplicated, from the data.

Counting every row in `message_nodes` is the obvious reading of the table, and
it is wrong: `message_nodes` is a DAG, and each turn re-materialises the whole
conversation chain as fresh nodes. One API call is therefore stored once per
turn that followed it.

This script counts both ways and prints the evidence that settles which is
right -- `metadata.request_id`. Rows that share a `request_id` are one API call,
however many rows they occupy.

Usage:
    python3 Scripts/devin_compare.py                 # this machine
    ssh server1 'python3 -' < Scripts/devin_compare.py

Exit code is 1 if the database is missing.
"""

import collections
import datetime
import json
import os
import sqlite3
import sys

DB = os.path.expanduser("~/.local/share/devin/cli/sessions.db")

FIELDS = ("input_tokens", "output_tokens", "cache_read_tokens",
          "cache_creation_tokens")
SHORT = ("input", "output", "cacheRead", "cacheWrite")


def commas(n):
    return format(n, ",")


def main():
    if not os.path.exists(DB):
        print("no Devin database at %s" % DB, file=sys.stderr)
        return 1

    conn = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)

    naive_rows = 0
    dedup_rows = 0
    naive = collections.Counter()
    dedup = collections.Counter()
    naive_day = collections.defaultdict(collections.Counter)
    dedup_day = collections.defaultdict(collections.Counter)
    groups = collections.defaultdict(list)
    seen = set()

    for node_id, chat, created, session in conn.execute(
            "SELECT node_id, chat_message, created_at, session_id"
            " FROM message_nodes ORDER BY row_id"):
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
        counts = tuple(metrics.get(f) or 0 for f in FIELDS)
        if sum(counts) <= 0:
            continue

        day = datetime.datetime.fromtimestamp(created).strftime("%Y-%m-%d")

        naive_rows += 1
        naive_day[day]["n"] += 1
        for name, value in zip(SHORT, counts):
            naive[name] += value
            naive_day[day][name] += value

        message_id = obj.get("message_id")
        groups[(session, message_id)].append(
            (node_id, metadata.get("request_id"), counts))

        if isinstance(message_id, str) and message_id:
            if (session, message_id) in seen:
                continue
            seen.add((session, message_id))

        dedup_rows += 1
        dedup_day[day]["n"] += 1
        for name, value in zip(SHORT, counts):
            dedup[name] += value
            dedup_day[day][name] += value

    conn.close()

    def table(label, rows, totals, by_day):
        print("== %s ==" % label)
        print("   rows=%s  total=%s" % (commas(rows), commas(sum(totals.values()))))
        for name in SHORT:
            print("      %-11s %16s" % (name, commas(totals[name])))
        for day in sorted(by_day):
            bucket = by_day[day]
            print("   %s  n=%-6s input=%-12s output=%-10s cacheRead=%s"
                  % (day, commas(bucket["n"]), commas(bucket["input"]),
                     commas(bucket["output"]), commas(bucket["cacheRead"])))

    table("NAIVE — every row counted", naive_rows, naive, naive_day)
    print()
    table("DEDUPED — one row per message_id", dedup_rows, dedup, dedup_day)
    print()

    naive_total = sum(naive.values())
    dedup_total = sum(dedup.values())
    if dedup_total:
        print("naive / deduped = %.3fx" % (naive_total / dedup_total))
    print()

    # The evidence. A shared request_id means a shared API call.
    multi = {k: v for k, v in groups.items() if len(v) > 1}
    same_request = 0
    differing_request = 0
    null_request = 0
    identical_tokens = 0
    for rows in multi.values():
        requests = set(r[1] for r in rows)
        if None in requests:
            null_request += 1
        elif len(requests) == 1:
            same_request += 1
        else:
            differing_request += 1
        if len(set(r[2] for r in rows)) == 1:
            identical_tokens += 1

    print("== evidence: %s message_ids are stored more than once ==" % commas(len(multi)))
    print("   groups sharing ONE request_id      : %s" % commas(same_request))
    print("   groups with DIFFERENT request_ids  : %s" % commas(differing_request))
    print("   groups with a null request_id      : %s" % commas(null_request))
    print("   groups with identical token counts : %s" % commas(identical_tokens))
    print()
    if multi:
        widest = max(multi.items(), key=lambda kv: len(kv[1]))
        print("   worked example — one call stored %d times:" % len(widest[1]))
        print("   session=%s message_id=%s" % (widest[0][0], widest[0][1]))
        for node_id, request_id, counts in widest[1]:
            print("      node_id=%-8s request_id=%-38s tokens=%s"
                  % (node_id, request_id, counts))
    print()
    if differing_request == 0 and null_request == 0 and multi:
        print("   Every duplicate group shares one request_id: the repeats are")
        print("   storage, not billing. The deduped figure is the API-call count.")
    else:
        print("   Not all groups share a request_id — re-check before trusting")
        print("   the deduped figure on this machine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
