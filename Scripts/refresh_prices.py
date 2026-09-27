#!/usr/bin/env python3
"""Regenerate Sources/TokenBar/Resources/model_prices.json from LiteLLM.

The app bundles a price snapshot rather than fetching at launch: it has to work
offline and give the same answer twice. This script refreshes that snapshot.

Source is LiteLLM's ``model_prices_and_context_window.json`` -- the same table
``ccusage`` prices against, which is why figures here are comparable to it.

Usage:
    python3 Scripts/refresh_prices.py            # fetch and write
    python3 Scripts/refresh_prices.py --dry-run  # report the diff, write nothing
    python3 Scripts/refresh_prices.py --from FILE

Output shape, chosen to keep the bundle small (~300 KB rather than ~2 MB):

    {"gpt-5.5": {"i": 1.25, "o": 10.0, "r": 0.125, "w": 1.5625}, ...}

``i``/``o``/``r``/``w`` are input / output / cache-read / cache-write in USD per
*million* tokens. LiteLLM stores per-token floats, so values are scaled by 1e6
here and Pricing.swift can divide by a round number.
"""
import argparse
import json
import os
import sys
import urllib.request

URL = ("https://raw.githubusercontent.com/BerriAI/litellm/main/"
       "model_prices_and_context_window.json")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Sources", "TokenBar", "Resources", "model_prices.json")

PER_MILLION = 1_000_000


def fetch(source):
    if source:
        with open(source, "rb") as handle:
            return json.load(handle)
    with urllib.request.urlopen(URL, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def convert(raw):
    """LiteLLM entry -> compact entry, or None when it cannot be priced."""
    if not isinstance(raw, dict):
        return None
    inp = raw.get("input_cost_per_token")
    out = raw.get("output_cost_per_token")
    # An entry pricing only one direction would under-report silently, which is
    # worse than reporting the model as unpriced. Both or nothing.
    if not isinstance(inp, (int, float)) or not isinstance(out, (int, float)):
        return None
    if inp <= 0 and out <= 0:
        return None

    entry = {"i": round(inp * PER_MILLION, 6), "o": round(out * PER_MILLION, 6)}
    # An explicit 0 means the model charges nothing for that tier and must be
    # kept: Pricing.swift falls back to the *input* rate when a field is absent,
    # so dropping a real zero silently bills cache traffic at full price. (39
    # entries set cache_creation to an explicit 0 upstream, including
    # deepseek-v4-flash-vision-exp, this machine's largest pi model.)
    read = raw.get("cache_read_input_token_cost")
    write = raw.get("cache_creation_input_token_cost")
    if isinstance(read, (int, float)) and read >= 0:
        entry["r"] = round(read * PER_MILLION, 6)
    if isinstance(write, (int, float)) and write >= 0:
        entry["w"] = round(write * PER_MILLION, 6)
    return entry


def build(raw):
    """Full table plus unambiguous bare-name aliases."""
    table = {}
    for name, value in raw.items():
        if name == "sample_spec":
            continue
        entry = convert(value)
        if entry is None:
            continue
        table[name.lower()] = entry

    # `provider/model` is how LiteLLM names most entries, but the CLIs log the
    # bare model. Alias it -- but only when every provider agrees on the price,
    # since picking one arbitrarily would quietly bill at another vendor's rate.
    candidates = {}
    for name, entry in table.items():
        if "/" not in name:
            continue
        bare = name.rsplit("/", 1)[1]
        if not bare or bare in table:
            continue
        candidates.setdefault(bare, []).append(entry)

    aliases = 0
    for bare, entries in candidates.items():
        first = json.dumps(entries[0], sort_keys=True)
        if all(json.dumps(e, sort_keys=True) == first for e in entries[1:]):
            table[bare] = entries[0]
            aliases += 1

    return table, aliases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change, write nothing")
    parser.add_argument("--from", dest="source", metavar="FILE",
                        help="read LiteLLM JSON from a local file instead of the network")
    args = parser.parse_args()

    try:
        raw = fetch(args.source)
    except Exception as exc:                       # noqa: BLE001 - reported, not raised
        print("fetch failed: %s" % exc, file=sys.stderr)
        return 1

    table, aliases = build(raw)
    if not table:
        print("refusing to write an empty table", file=sys.stderr)
        return 1

    previous = {}
    if os.path.exists(OUT):
        try:
            with open(OUT) as handle:
                previous = json.load(handle)
        except ValueError:
            pass

    added = sorted(set(table) - set(previous))
    removed = sorted(set(previous) - set(table))
    changed = [k for k in set(table) & set(previous) if table[k] != previous[k]]

    print("models: %d (%d bare-name aliases)" % (len(table), aliases))
    print("added: %d  removed: %d  repriced: %d" % (len(added), len(removed), len(changed)))
    for name in added[:10]:
        print("  + %s" % name)
    for name in removed[:10]:
        print("  - %s" % name)
    for name in sorted(changed)[:10]:
        print("  ~ %s  %s -> %s" % (name, previous[name], table[name]))

    # A mass disappearance means the upstream format moved, not that the models
    # went away; writing that would silently unprice most of the app.
    if previous and len(removed) > len(previous) // 2:
        print("refusing to write: over half the previous models vanished",
              file=sys.stderr)
        return 1

    if args.dry_run:
        print("dry run: %s not written" % OUT)
        return 0

    with open(OUT, "w") as handle:
        json.dump(table, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
    print("wrote %s (%.1f KB)" % (OUT, os.path.getsize(OUT) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
