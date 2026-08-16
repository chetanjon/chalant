#!/usr/bin/env python3
"""Is the engine's confidence any good at telling you which words are wrong?

Phase 0 established that `transcriptionConfidence` is populated on 100% of
finalized runs and varies from 0.011 to 0.998, and then said the thing that
matters: "present and varying is not meaningful". The directive's bar is
**AUC > 0.70 against per-word error**, and answering it needed the corpus.

The corpus now exists and the tokens now carry confidence, so this answers it.

AUC here is the probability that a randomly chosen WRONG word was less
confident than a randomly chosen RIGHT one. 0.50 is a coin flip. Below the bar
means confidence cannot be used to decide which words to repair, however
convenient that would be.

usage: calibration.py <probe.jsonl>
"""
import json
import re
import sys
import collections


def toks(s):
    return re.findall(r"[\w'@./_-]+|[^\w\s]", s.lower())


def align(ref, hyp):
    """Levenshtein backtrace -> ops, same shape score.py uses."""
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
    ops, i, j = [], n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i - 1] == hyp[j - 1] and d[i][j] == d[i - 1][j - 1]:
            ops.append(("ok", j - 1)); i -= 1; j -= 1
        elif i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + 1:
            ops.append(("sub", j - 1)); i -= 1; j -= 1
        elif j > 0 and d[i][j] == d[i][j - 1] + 1:
            ops.append(("ins", j - 1)); j -= 1
        else:
            ops.append(("del", None)); i -= 1
    return list(reversed(ops))


def auc(labelled):
    """Probability a wrong word scores lower confidence than a right one."""
    wrong = [c for c, bad in labelled if bad]
    right = [c for c, bad in labelled if not bad]
    if not wrong or not right:
        return float("nan")
    better = ties = 0
    for w in wrong:
        for r in right:
            if w < r:
                better += 1
            elif w == r:
                ties += 1
    return (better + 0.5 * ties) / (len(wrong) * len(right))


rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
by_split = collections.defaultdict(list)

for row in rows:
    detail = row.get("detail") or []
    # score.py's tokenizer splits punctuation off; the engine's tokens do not.
    # Compare on the engine's own words so a token maps to one confidence.
    hyp = [d["t"].strip(".,?!\"()").lower() for d in detail]
    conf = [d["c"] for d in detail]
    ref = [t for t in toks(row["desired"]) if re.search(r"\w", t)]
    if not hyp or not ref:
        continue
    bad = set()
    for op, index in align(ref, hyp):
        if op in ("sub", "ins") and index is not None:
            bad.add(index)
    for i, c in enumerate(conf):
        if c is not None:
            by_split[row["split"]].append((c, i in bad))

print(f"{'split':<12}{'words':>7}{'wrong':>7}{'AUC':>8}   mean confidence")
print("-" * 62)
everything = []
for split, labelled in sorted(by_split.items()):
    everything += labelled
    wrong = [c for c, b in labelled if b]
    right = [c for c, b in labelled if not b]
    value = auc(labelled)
    print(f"{split:<12}{len(labelled):>7}{len(wrong):>7}{value:>8.3f}   "
          f"wrong {sum(wrong)/len(wrong):.3f} vs right {sum(right)/len(right):.3f}")

wrong = [c for c, b in everything if b]
right = [c for c, b in everything if not b]
print("-" * 62)
print(f"{'ALL':<12}{len(everything):>7}{len(wrong):>7}{auc(everything):>8.3f}   "
      f"wrong {sum(wrong)/len(wrong):.3f} vs right {sum(right)/len(right):.3f}")
print("\nbar: AUC > 0.70 to be usable as a repair gate.")

# What a threshold actually buys, since that is how the gate is written.
print("\nif the gate fires below a confidence floor:")
print(f"{'floor':>7}{'caught':>9}{'missed':>9}{'false':>9}   precision")
for floor in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]:
    caught = sum(1 for c, b in everything if b and c < floor)
    missed = sum(1 for c, b in everything if b and c >= floor)
    false = sum(1 for c, b in everything if not b and c < floor)
    precision = caught / (caught + false) if caught + false else float("nan")
    print(f"{floor:>7.1f}{caught:>9}{missed:>9}{false:>9}   {precision:>8.1%}")
