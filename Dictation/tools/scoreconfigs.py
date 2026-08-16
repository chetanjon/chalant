#!/usr/bin/env python3
"""Score every configuration signalprobe produced, side by side.

`score.py` grades one manifest. `signalprobe` emits several configurations
interleaved in one file, so this splits them back apart, scores each, and prints
the comparison as a table. The split matters: the `torture` set is LOCKED
English and is the number every earlier entry in EVAL-LOG.md is quoted against,
so it is the one a decision may be taken on.

usage: scoreconfigs.py <probe.jsonl> <terms.txt> <corpusdir>
"""
import collections
import json
import re
import subprocess
import sys
import tempfile
import os

probe_path, terms_path, corpus_dir = sys.argv[1], sys.argv[2], sys.argv[3]

rows = [json.loads(line) for line in open(probe_path) if line.strip()]
by_config = collections.defaultdict(list)
for row in rows:
    by_config[row["config"]].append(row)

splits = sorted({row["split"] for row in rows})
score_py = os.path.join(corpus_dir, "score.py")

CORRECTIONS = re.compile(r"CORRECTIONS PER 100 WORDS:\s*([\d.]+)")
CLASSES = re.compile(r"^ {2}(\w+)\s+(\d+)\s+\(", re.MULTILINE)


def score(config_rows, split):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for row in config_rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        path = f.name
    out = subprocess.run(
        ["python3", score_py, path, "--terms", terms_path, "--split", split],
        capture_output=True, text=True, cwd=corpus_dir).stdout
    os.unlink(path)
    match = CORRECTIONS.search(out)
    classes = dict(CLASSES.findall(out.split("by error class:")[1])) if "by error class:" in out else {}
    return (float(match.group(1)) if match else float("nan")), classes


order = ["speech", "speech-biased", "speech-control",
         "dictation", "dictation-biased", "dictation-control"]
configs = [c for c in order if c in by_config] + \
          [c for c in by_config if c not in order]

for split in splits:
    print(f"\n=== split: {split} ===")
    header = f"{'config':<20}{'corr/100w':>10}   error classes"
    print(header)
    print("-" * len(header))
    for config in configs:
        value, classes = score(by_config[config], split)
        detail = "  ".join(f"{k}={v}" for k, v in sorted(classes.items(), key=lambda kv: -int(kv[1])))
        print(f"{config:<20}{value:>10.2f}   {detail}")

# Confidence coverage, which is the other half of why this run exists.
print("\n=== signal coverage ===")
for config in configs:
    config_rows = by_config[config]
    tokens = sum(r["tokens"] for r in config_rows)
    with_conf = sum(r["withConfidence"] for r in config_rows)
    alts = sum(r["alternatives"] for r in config_rows)
    means = [r["meanConfidence"] for r in config_rows if r["meanConfidence"] is not None]
    pct = 100 * with_conf / tokens if tokens else 0
    mean = sum(means) / len(means) if means else float("nan")
    print(f"{config:<20} {with_conf}/{tokens} tokens carry confidence ({pct:.1f}%), "
          f"mean {mean:.3f}, {alts} alternatives")

# Determinism: a config and its control saw identical audio through identical
# settings, so any difference between them is the module's own variance and
# bounds how large a difference elsewhere is allowed to mean anything.
print("\n=== determinism (config vs its control) ===")
for base in ["speech", "dictation"]:
    control = f"{base}-control"
    if base not in by_config or control not in by_config:
        continue
    a = {r["id"]: r["output"] for r in by_config[base]}
    b = {r["id"]: r["output"] for r in by_config[control]}
    differing = [k for k in a if a.get(k) != b.get(k)]
    print(f"{base:<20} {len(differing)}/{len(a)} utterances differ between two identical runs")
    for k in differing[:5]:
        print(f"    {k}\n      A: {a[k][:90]}\n      B: {b[k][:90]}")
