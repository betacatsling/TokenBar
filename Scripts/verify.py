#!/usr/bin/env python3
"""Swift/production-Python parity on live roots, not independent correctness.
Known-answer fixtures test accounting semantics separately. No source log writes.
"""
import argparse
import collections
import importlib.util
import json
import os
from pathlib import Path
from datetime import datetime, timedelta

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tokenbar_remote', ROOT / 'Sources/TokenBar/Resources/remote_collect.py')
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
FIELDS = ('input', 'output', 'cacheRead', 'cacheWrite', 'cacheWrite1h')


def collect_all(include_sidechain=False):
    home = str(Path.home())
    claude = os.environ.get('CLAUDE_CONFIG_DIR') or home + '/.claude'
    codex = os.environ.get('CODEX_HOME') or home + '/.codex'
    pi = os.environ.get('PI_CODING_AGENT_DIR') or home + '/.pi/agent'
    xdg = os.environ.get('XDG_DATA_HOME') or home + '/.local/share'
    gemini = os.environ.get('GEMINI_CLI_HOME') or home + '/.gemini'
    magpie = os.environ.get('MAGPIE_CONFIG_DIR') or home + '/.config/magpie'
    roots = [codex + '/sessions', codex + '/archived_sessions']
    results = {
        'claude-code': (remote.collect_claude(claude + '/projects'), len(remote.walk_jsonl(claude + '/projects'))),
        'codex': (remote.collect_codex(roots), len(remote.rollout_files(roots))),
        'devin': (remote.collect_devin(xdg + '/devin/cli/sessions.db'), int(Path(xdg + '/devin/cli/sessions.db').exists())),
        'pi': (remote.collect_pi(pi), len(remote.walk_jsonl(pi + '/sessions'))),
        'gemini': (remote.collect_gemini(gemini), len(list(Path(gemini + '/tmp').glob('*/chats/session-*.json')))),
        'opencode': (remote.collect_opencode(xdg + '/opencode'), int(Path(xdg + '/opencode/opencode.db').exists())),
        'magpie': (remote.collect_magpie(magpie), int(Path(magpie + '/usage.jsonl').exists())),
    }
    return {cli: ([b for b in buckets if include_sidechain or not b.get('sidechain')], files)
            for cli, (buckets, files) in results.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-sidechain', action='store_true')
    parser.add_argument('--models', action='store_true')
    parser.add_argument('--naive', action='store_true')
    args = parser.parse_args()
    results = collect_all(args.include_sidechain)
    print('== TokenBar verify (production Python parity) ==')
    print('date: ' + remote.today())
    print('includeSidechain: ' + str(args.include_sidechain))
    by_cli, by_day, by_model = collections.Counter(), collections.Counter(), collections.Counter()
    for cli, (buckets, files) in results.items():
        for b in buckets:
            n = sum(b.get(k, 0) for k in FIELDS)
            by_cli[cli] += n
            by_day[b['day']] += n
            by_model[b['model']] += n
        print('%-14s files=%-6d tokens=%-14d' % (cli, files, by_cli[cli]))
    print('----')
    print('total_tokens: %d' % sum(by_cli.values()))
    for key in sorted(by_cli):
        print('cli.%s: %d' % (key, by_cli[key]))
    for offset in reversed(range(14)):
        day = (datetime.now() - timedelta(days=offset)).strftime('%Y-%m-%d')
        print('day.%s: %d' % (day, by_day[day]))
    if args.models:
        print('----')
        for model in sorted(by_model):
            print('model.%s: %d' % (model, by_model[model]))
    if args.naive:
        claude = os.environ.get('CLAUDE_CONFIG_DIR') or str(Path.home()) + '/.claude'
        naive = 0
        for path in remote.walk_jsonl(claude + '/projects'):
            for line in remote.read_lines(path):
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get('type') != 'assistant':
                    continue
                message = obj.get('message') or {}
                if message.get('model') == '<synthetic>':
                    continue
                usage = message.get('usage') or {}
                naive += sum(remote.as_int(usage.get(k)) for k in
                             ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
        print('claude_naive_sum: %d' % naive)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
