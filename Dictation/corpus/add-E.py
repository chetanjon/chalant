#!/usr/bin/env python3
"""Append set E to the corpus manifest once it has been recorded.

Set E is written so that what was SAID is exactly what should be INSERTED, so
`desired` is the prompt itself and `verbatim` is null. That is the whole reason
the sentences avoid spoken numbers: it makes the ground truth free rather than a
labelling session, and it keeps the vocabulary question separate from the
number-formatting one.

Part 4's split discipline applies: 20 dev, 10 holdout, so thresholds can be
swept on dev without quietly overfitting the set that is meant to check them.
The assignment is fixed rather than random, so re-running this cannot silently
reshuffle which utterances are protected.

Refuses to run twice. The corpus is immutable once labelled: the moment ground
truth is revised mid-project, every comparison against an earlier run stops
meaning anything, and regression tracking was the entire point.

usage: python3 add-E.py   (from ~/Desktop/chalant-corpus)
"""
import json
import os
import sys

HOLDOUT = {"E03", "E07", "E11", "E14", "E18", "E21", "E24", "E27", "E29", "E30"}

if not os.path.exists("manifest.jsonl"):
    sys.exit("no manifest.jsonl here. Run this from ~/Desktop/chalant-corpus")

existing = [json.loads(line) for line in open("manifest.jsonl") if line.strip()]
if any(row["id"].startswith("E") for row in existing):
    sys.exit("set E is already in the manifest. Refusing to add it twice.")

rows = []
missing = []
for line in open("prompts-E.tsv"):
    line = line.rstrip("\n")
    if not line:
        continue
    ident, sentence = line.split("\t", 1)
    audio = f"audio-E/{ident}.caf"
    if not os.path.exists(audio):
        missing.append(audio)
    rows.append({
        "id": ident,
        "context": "propernoun",
        "split": "holdout" if ident in HOLDOUT else "dev",
        "audio": audio,
        "desired": sentence,
        "verbatim": None,
        "note": "",
    })

if missing:
    sys.exit(f"{len(missing)} recordings are missing, first is {missing[0]}. "
             "Record set E before adding it.")

with open("manifest.jsonl", "a") as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

# **Without this the whole set measures nothing.** `score.py` classifies an
# error as `proper_noun` only when the token is in `terms.txt`; anything else
# falls to `other`. Adding 30 proper-noun utterances without adding their names
# would leave the one metric M4 is accepted on flat by construction, and it
# would look like the set had failed rather than the scorer.
NEW_TERMS = """
jonnalagadda wispr superwhisper willow whisper fluidaudio parakeet coreml
posthog supabase elevenlabs homebrew xcode sparkle grdb prybar ikt mixpanel
vercel figma sfspeechrecognizer appcast
""".split()

known = {t.strip().lower() for t in open("terms.txt") if t.strip()}
added = [t for t in NEW_TERMS if t not in known]
if added:
    with open("terms.txt", "a") as f:
        for term in added:
            f.write(term + "\n")

print(f"added {len(rows)} rows ({sum(1 for r in rows if r['split'] == 'dev')} dev, "
      f"{sum(1 for r in rows if r['split'] == 'holdout')} holdout)")
print(f"added {len(added)} terms to terms.txt (now {len(known) + len(added)}; "
      "§0.13 caps an ACTIVE bias list at 100, which this is not)")
print("now: signalprobe . manifest.jsonl terms.txt en_US speech")
