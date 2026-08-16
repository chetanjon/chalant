#!/usr/bin/env python3
"""Is "it is a routing decision" worth anything, or is it a slogan?

Two modules each win on their own ground. That only matters if something can
pick the winner per utterance. This measures three things:

  floor    the better single module, which is what shipping one engine buys
  oracle   picking the better module per utterance with perfect knowledge,
           which is the ceiling any router can reach
  routed   picking with a signal actually available at runtime

If oracle is close to floor, routing is not worth building and the answer is to
ship the better module. The gap between routed and oracle is what a smarter
router could still earn.

usage: routing.py <probe.jsonl> ... <terms.txt>
"""
import collections
import json
import re
import sys

paths = sys.argv[1:-1]
terms = {t.strip().lower() for t in open(sys.argv[-1]) if t.strip()}


def toks(s):
    return re.findall(r"[\w'@./_-]+|[^\w\s]", s.lower())


def distance(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1,
                          d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    return d[n][m]


rows = []
for path in paths:
    locale = path.split("probe-")[-1].replace(".jsonl", "")
    for line in open(path):
        if line.strip():
            row = json.loads(line)
            row["locale"] = locale
            rows.append(row)

# Control runs exist to measure the module's own variance, not to compete.
rows = [r for r in rows if not r["config"].endswith("-control")]

by_utterance = collections.defaultdict(dict)
meta = {}
for row in rows:
    key = row["id"]
    name = f"{row['config']}@{row['locale']}"
    ref = toks(row["desired"])
    by_utterance[key][name] = {
        "errors": distance(ref, toks(row["output"])),
        "words": len(ref),
        "meanConfidence": row["meanConfidence"],
        "minConfidence": row["minConfidence"],
        "output": row["output"],
    }
    meta[key] = {"split": row["split"], "desired": row["desired"]}

configs = sorted({f"{r['config']}@{r['locale']}" for r in rows})
splits = sorted({m["split"] for m in meta.values()})


def rate(errors, words):
    return 100 * errors / words if words else float("nan")


for split in splits:
    keys = [k for k in by_utterance if meta[k]["split"] == split]
    words = sum(by_utterance[k][configs[0]]["words"] for k in keys)
    print(f"\n=== split: {split}  ({len(keys)} utterances, {words} words) ===")

    totals = {}
    for config in configs:
        total = sum(by_utterance[k].get(config, {}).get("errors", 0) for k in keys)
        totals[config] = total
        print(f"  {config:<26} {rate(total, words):>7.2f}")

    best_single = min(totals, key=totals.get)
    print(f"\n  floor  (best single engine: {best_single})   "
          f"{rate(totals[best_single], words):>7.2f}")

    oracle = sum(min(by_utterance[k][c]["errors"] for c in by_utterance[k]) for k in keys)
    print(f"  oracle (best engine per utterance)          {rate(oracle, words):>7.2f}")

    # A router that can actually run: pick the reading the engine itself was
    # least unsure about. Confidence is the only per-utterance signal available
    # before the answer is known.
    routed = 0
    for k in keys:
        pick = max(
            by_utterance[k],
            key=lambda c: by_utterance[k][c]["meanConfidence"] or 0)
        routed += by_utterance[k][pick]["errors"]
    print(f"  routed (highest mean confidence wins)       {rate(routed, words):>7.2f}")

    won = collections.Counter(
        min(by_utterance[k], key=lambda c: by_utterance[k][c]["errors"]) for k in keys)
    print("\n  utterances won outright: " +
          ", ".join(f"{c.split('@')[0]}@{c.split('@')[1]}={n}" for c, n in won.most_common()))
