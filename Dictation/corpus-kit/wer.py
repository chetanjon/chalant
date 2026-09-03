#!/usr/bin/env python3
"""Word error rate against a public reference, scored the way the field does.

`score.py` is the product metric: it counts corrections a person would have
to make, punctuation included, against a `desired` written by the user. That
is the right measure for dictation and the wrong one for a public benchmark,
whose references carry no punctuation and no case at all: scored raw, every
full stop the app correctly adds reads as an error.

So this normalises the way ASR papers do before aligning: lowercase, strip
punctuation, collapse whitespace. Two numbers come out, and both are printed
because the difference between them is itself a finding:

  WER              after that normalisation
  WER, numbers written out    also mapping 0-20, the tens, hundred and
                              thousand back to words, because inverse text
                              normalisation ("twenty three" -> "23") is a
                              FEATURE that a word-level reference scores as
                              two errors.

Usage: wer.py <hypotheses.jsonl> <references.tsv>
  hypotheses.jsonl   {"id", "raw"} per line, as tools/transcribe writes
  references.tsv     "<id>\\t<reference text>" per line
"""
import json
import re
import sys

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = {20: "twenty", 30: "thirty", 40: "forty", 50: "fifty", 60: "sixty",
        70: "seventy", 80: "eighty", 90: "ninety"}


def spell(n):
    """Small integers back to words. Deliberately covers only what dictation
    actually turns into digits; anything else is left alone rather than
    guessed at."""
    if n < 20:
        return ONES[n]
    if n < 100:
        rest = n % 10
        return TENS[n - rest] + ("" if rest == 0 else " " + ONES[rest])
    if n < 1000 and n % 100 == 0:
        return ONES[n // 100] + " hundred"
    return None


def normalise(text, numbers=False):
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    words = []
    for word in text.split():
        if numbers and word.isdigit():
            spelled = spell(int(word))
            if spelled:
                words.extend(spelled.split())
                continue
        words.append(word)
    return words


def distance(ref, hyp):
    """Levenshtein over words, the standard WER edit distance."""
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i]
        for j, h in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (r != h)))
        previous = current
    return previous[-1]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    hyps = {}
    for line in open(sys.argv[1]):
        if not line.strip():
            continue
        row = json.loads(line)
        hyps[row["id"]] = row.get("raw", "")
    refs = {}
    for line in open(sys.argv[2]):
        if "\t" not in line:
            continue
        key, text = line.rstrip("\n").split("\t", 1)
        refs[key] = text

    shared = [k for k in refs if k in hyps]
    missing = len(refs) - len(shared)
    for label, numbers in (("WER", False), ("WER, numbers written out", True)):
        errors = words = 0
        worst = []
        for key in shared:
            r = normalise(refs[key], numbers)
            h = normalise(hyps[key], numbers)
            d = distance(r, h)
            errors += d
            words += len(r)
            if d:
                worst.append((d / max(len(r), 1), key, " ".join(r), " ".join(h)))
        print(f"{label}: {100 * errors / max(words, 1):.2f}%  "
              f"({errors} errors / {words} words, {len(shared)} utterances)")
        if numbers:
            worst.sort(reverse=True)
            print("\nworst utterances:")
            for rate, key, r, h in worst[:5]:
                print(f"  {key}  {100 * rate:.0f}%")
                print(f"    ref: {r[:110]}")
                print(f"    got: {h[:110]}")
    if missing:
        print(f"\n{missing} reference utterances had no hypothesis (not transcribed).")


main()
