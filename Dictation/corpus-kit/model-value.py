#!/usr/bin/env python3
"""What does the model buy? Value, behaviour, cost and the 40-character line.

usage: model-value.py <manifest.jsonl> <runs-dir> <out-table.jsonl> [captured.jsonl]

manifest.jsonl: the Desktop corpus manifest, for `desired` (truth) per id.
runs-dir: holds what-set{C,D,E}-{ungated,gated}.jsonl from tools/textpath.
out-table.jsonl: one line per row: id, set, asrRaw, afterDeterministic, final,
  truth, modelReason, polishSeconds, corrections before/after, verdict.
captured.jsonl (optional): the real corpus, for restating the L6 proxy over
  the same 20 rows the 2026-08-21 audit used.

Scoring is score.py's: its tokenizer and alignment are copied verbatim below
(score.py runs main() on import), corrections = every non-matching token
against the truth, per 100 reference words.
"""
import json, os, re, statistics, sys
from collections import Counter, defaultdict


# --- score.py, verbatim ------------------------------------------------------
def toks(s):
    return re.findall(r"[\w'@./_-]+|[^\w\s]", s.lower())


def align(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    ops, i, j = [], n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i - 1] == hyp[j - 1] and d[i][j] == d[i - 1][j - 1]:
            ops.append(('ok', ref[i - 1], hyp[j - 1])); i -= 1; j -= 1
        elif i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + 1:
            ops.append(('sub', ref[i - 1], hyp[j - 1])); i -= 1; j -= 1
        elif j > 0 and d[i][j] == d[i][j - 1] + 1:
            ops.append(('ins', None, hyp[j - 1])); j -= 1
        else:
            ops.append(('del', ref[i - 1], None)); i -= 1
    return list(reversed(ops))
# -----------------------------------------------------------------------------


def corrections(truth, text):
    return [o for o in align(toks(truth), toks(text)) if o[0] != 'ok']


# Fillers.noise plus the "like" rule and the two asides, Disfluency's repeats.
FILLERS = {"uh", "um", "erm", "uhh", "umm", "hmm", "mmm", "like", "you know", "i mean"}
PUNCT = set(",.?!;:-")


def cased_toks(s):
    return re.findall(r"[\w'@./_-]+|[^\w\s]", s)


def classify_edits(before, after):
    """Every token-level edit from before to after, by class."""
    ops = align(cased_toks(before), cased_toks(after))
    out, prev_kept = [], None
    for op, a, b in ops:
        if op == 'ok':
            prev_kept = a
            continue
        if op == 'del':
            if a in PUNCT:
                out.append(('punctuation', f"-{a}"))
            elif a.lower().strip("'") in FILLERS or (prev_kept and a.lower() == prev_kept.lower()):
                out.append(('filler/repeat deletion', f"-{a}"))
            else:
                out.append(('other deletion', f"-{a}"))
        elif op == 'ins':
            out.append(('punctuation' if b in PUNCT else 'other', f"+{b}"))
        else:
            if a.lower() == b.lower():
                out.append(('case', f"{a}->{b}"))
            elif a in PUNCT and b in PUNCT:
                out.append(('punctuation', f"{a}->{b}"))
            else:
                out.append(('other', f"{a}->{b}"))
    return out


def load_run(path):
    rows = []
    for line in open(path):
        r = json.loads(line)
        if r.get("kind") != "meta":
            rows.append(r)
    return rows


def pct(v, q):
    s = sorted(v)
    return s[min(len(s) - 1, int(round((len(s) - 1) * q)))] if s else float('nan')


def main():
    manifest, runs, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    captured = sys.argv[4] if len(sys.argv) > 4 else None
    truth = {r["id"]: r["desired"] for r in (json.loads(l) for l in open(manifest) if l.strip())}

    table, edits_by_class, per_set = [], defaultdict(list), {}
    for S in ("C", "D", "E"):
        ung = load_run(f"{runs}/what-set{S}-ungated.jsonl")
        gat = {r["id"]: r for r in load_run(f"{runs}/what-set{S}-gated.jsonl")}
        ref_words = before_errs = after_errs = 0
        verdicts = Counter()
        closer, farther = [], []
        for r in ung:
            t = truth[r["id"]]
            det, fin = r["afterDeterministic"], r["inserted"]
            eb, ea = corrections(t, det), corrections(t, fin)
            ref_words += len(toks(t)); before_errs += len(eb); after_errs += len(ea)
            v = "closer" if len(ea) < len(eb) else ("farther" if len(ea) > len(eb) else "equal")
            verdicts[v] += 1
            rec = {"id": r["id"], "set": S, "asrRaw": r["asrRaw"], "afterDeterministic": det, "final": fin,
                   "truth": t, "modelReason": r["modelReason"], "polishSeconds": r["polishSeconds"],
                   "correctionsBefore": len(eb), "correctionsAfter": len(ea), "verdict": v,
                   "gatedReason": gat[r["id"]]["modelReason"], "chars": len(det.strip())}
            table.append(rec)
            if v == "closer": closer.append(rec)
            if v == "farther": farther.append(rec)
            if r["modelReason"] == "landed" and r["modelOutput"] not in (None, det):
                for cls, edit in classify_edits(det, r["modelOutput"]):
                    edits_by_class[cls].append((r["id"], edit, det, r["modelOutput"]))
        per_set[S] = dict(words=ref_words, before=before_errs, after=after_errs, verdicts=verdicts,
                          closer=closer, farther=farther, rows=len(ung))

    with open(out_path, "w") as f:
        for rec in table:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print("=== 1. VALUE (score.py corrections per 100 reference words) ===")
    for S, d in per_set.items():
        print(f"Set {S}: {d['rows']} rows, {d['words']} words | afterDeterministic {100*d['before']/d['words']:.2f} ({d['before']}) | "
              f"final {100*d['after']/d['words']:.2f} ({d['after']}) | closer {d['verdicts']['closer']}, equal {d['verdicts']['equal']}, farther {d['verdicts']['farther']}")
    tw = sum(d['words'] for d in per_set.values()); tb = sum(d['before'] for d in per_set.values()); ta = sum(d['after'] for d in per_set.values())
    print(f"All 90: {tw} words | afterDeterministic {100*tb/tw:.2f} ({tb}) | final {100*ta/tw:.2f} ({ta})")
    for kind in ("closer", "farther"):
        print(f"-- {kind} rows --")
        for S, d in per_set.items():
            for rec in d[kind]:
                print(f"  {rec['id']} [{rec['modelReason']}] {rec['correctionsBefore']}->{rec['correctionsAfter']}: {rec['afterDeterministic']!r} -> {rec['final']!r}  (truth: {rec['truth']!r})")

    print("\n=== 2. WHAT THE MODEL DOES (edits in landed rows where it changed the text) ===")
    for cls in ("filler/repeat deletion", "other deletion", "punctuation", "case", "other"):
        items = edits_by_class.get(cls, [])
        print(f"{cls}: {len(items)} edits in {len({i for i,_,_,_ in items})} rows")
        for rid, edit, det, mo in items:
            print(f"    {rid}: {edit}   | {det!r} -> {mo!r}")

    print("\n=== 3. COST ===")
    times = [rec["polishSeconds"] for rec in table]
    over = [rec for rec in table if rec["polishSeconds"] > 0.65]
    print(f"polish per call (90 ungated rows): median {statistics.median(times):.3f} s, p95 {pct(times,0.95):.3f} s, max {max(times):.3f} s, "
          f"over the 0.65 s budget: {len(over)} rows ({', '.join(r['id'] for r in over)})")
    greedy_median = statistics.median(times)
    if captured and os.path.exists(captured):
        rows = [json.loads(l) for l in open(captured) if l.strip()]
        utt = [r for r in rows if r.get("kind") != "hearing" and r.get("recorded", "") <= "2026-08-22T02:47:18Z"][-20:]
        def sums(polish_of):
            return [r.get("finalizeSeconds", 0) + r.get("prepareSeconds", 0) + polish_of(r) + r.get("insertSeconds", 0) for r in utt]
        actual = sums(lambda r: r.get("polishSeconds", 0))
        greedy = sums(lambda r: greedy_median if r.get("polishSeconds", 0) > 0 else 0)
        none = sums(lambda r: 0)
        print(f"L6 proxy over the audit's 20 real rows: as measured median {statistics.median(actual):.3f} p95 {pct(actual,0.95):.3f} | "
              f"polish at the greedy median ({greedy_median:.3f} s) on rows that polished: median {statistics.median(greedy):.3f} p95 {pct(greedy,0.95):.3f} | "
              f"model removed: median {statistics.median(none):.3f} p95 {pct(none,0.95):.3f}")

    print("\n=== 4. THE 40-CHARACTER LINE ===")
    for S in ("C", "D", "E"):
        gat = load_run(f"{runs}/what-set{S}-gated.jsonl")
        sent = [r for r in gat if r["modelReason"] != "gated"]
        print(f"Set {S} gated: {len(sent)} of {len(gat)} rows reached the model: {[r['id'] for r in sent]}")
        for r in sent:
            if r["modelOutput"] not in (None, r["afterDeterministic"]):
                print(f"    changed {r['id']} [{r['modelReason']}]: {r['afterDeterministic']!r} -> {r['modelOutput']!r}")
            elif r["modelReason"] != "landed":
                print(f"    {r['id']}: {r['modelReason']}")
    short = [rec for rec in table if rec["chars"] <= 40]
    helped = [rec for rec in short if rec["verdict"] == "closer"]
    hurt = [rec for rec in short if rec["verdict"] == "farther"]
    print(f"rows at or under 40 characters: {len(short)}; ungated, the model moved closer on {len(helped)}, farther on {len(hurt)}")
    for rec in helped + hurt:
        print(f"    {rec['id']} ({rec['verdict']}, {rec['chars']} chars): {rec['afterDeterministic']!r} -> {rec['final']!r}  (truth: {rec['truth']!r})")


if __name__ == "__main__":
    main()
