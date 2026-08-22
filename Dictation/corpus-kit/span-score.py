#!/usr/bin/env python3
"""Protected-span mutation rate of the post-ASR text path.

usage: span-score.py <annotations.json> <outputs.jsonl> [--json]

annotations: rows in STAGE1_DIRECTIVE.md §2.3 format ({"id", "truth",
  "protected_spans", ...}), e.g. Dictation/corpus/setC.json. For real
  dictations, write the same shape keyed by the captured row's id.
outputs: one JSON object per line with the corpus row's schema-3 names.
  Input text is `asrRaw`. Output text is the first non-null of `inserted`,
  `output`, `modelOutput`, `afterDeterministic`. Lines whose "kind" is
  "meta" or "hearing" are skipped; a "shadow" line (the model's reply
  written after its row, in shadow mode) is merged into its row. Rows are joined on `id`; annotated rows
  with no output row are reported, never silently dropped. Runs unchanged
  on a tools/textpath run file and on ~/Desktop/chalant-corpus/captured/
  captured.jsonl.

The rules (founder, 2026-08-21; Dictation/corpus/README-set-C.md):
 1. presence and mutation are case-insensitive; "case drift" (present in
    both, exact-case count lower in the output) is its own count and does
    not feed the rate.
 2. a contraction or expansion ("do not" <-> "don't") is a mutation,
    labelled `contraction`.
 3. numbers are verbatim, never normalised; a mutation whose digits match
    after stripping commas, spaces and currency symbols is labelled
    `format-only`. Both feed the rate.
 4. whole-word matching at boundaries (start/end of text, whitespace,
    punctuation); present if the span occurs >= 1 time in the input;
    mutated if its count in the output is lower than in the input.
 5. negation tokens (not, no, never, n't as a suffix, without, nor) are
    counted in input and output per row; any difference is a mutation,
    labelled `negation added` / `negation dropped`.
Two small reading conventions, stated so they can be argued with: U+2019
is read as an apostrophe before matching (an encoding detail, not an
edit), and "cannot" counts as one negation (it is "can" + "not", so an
expansion of "can't" does not read as a dropped negation).

Mutation rate = mutated / present across all rows. Spans absent from the
input are ASR misses, listed by row, never counted as mutations.

Self-corrections (Set F, 2026-08-22): an annotation row may carry
`retracted` (values the speaker withdrew) and `corrected` (what replaced
them). Per run the scorer reports, as its own counts and never inside the
rate: retracted values the ASR heard (present in the input), retracted
values that survived into the output, corrected values present in the
output, and rows handled correctly (every corrected value present AND every
retracted value absent from the output). Each
mutation also names the stage where the span first went missing
(deterministic: asrRaw -> afterDeterministic; model: afterDeterministic
-> modelOutput; final: anything after), when those fields are present.
"""
import json, re, sys
from collections import Counter, OrderedDict

NEGATION_WORDS = {"not", "no", "never", "without", "nor", "cannot"}
CONTRACTIONS = {
    "do not": "don't", "does not": "doesn't", "did not": "didn't", "cannot": "can't",
    "can not": "can't", "will not": "won't", "would not": "wouldn't",
    "should not": "shouldn't", "could not": "couldn't", "is not": "isn't",
    "are not": "aren't", "was not": "wasn't", "were not": "weren't",
    "has not": "hasn't", "have not": "haven't", "had not": "hadn't",
    "must not": "mustn't", "it is": "it's", "i am": "i'm", "we are": "we're",
    "they are": "they're", "i will": "i'll", "i have": "i've", "that is": "that's",
}
EXPANSIONS = {}
for _long, _short in CONTRACTIONS.items():
    EXPANSIONS.setdefault(_short, []).append(_long)


def norm(text):
    return (text or "").replace("’", "'").replace("‘", "'")


def count(span, text, case_sensitive=False):
    """Occurrences of span in text at word boundaries (rule 4)."""
    s, t = norm(span), norm(text)
    if not case_sensitive:
        s, t = s.lower(), t.lower()
    n, i = 0, 0
    while True:
        j = t.find(s, i)
        if j < 0 or not s:
            return n
        before = t[j - 1] if j > 0 else ""
        end = j + len(s)
        after = t[end] if end < len(t) else ""
        if (not before or not before.isalnum()) and (not after or not after.isalnum()):
            n += 1
            i = end
        else:
            i = j + 1


def negations(text):
    words = re.findall(r"[a-z]+(?:'[a-z]+)?", norm(text).lower())
    return sum(1 for w in words if w in NEGATION_WORDS or w.endswith("n't"))


def digits_key(s):
    return re.sub(r"[,\s$€£]", "", norm(s).lower())


def number_candidates(text):
    return re.findall(r"[$€£]?\d[\d,.:]*\d|[$€£]?\d", norm(text))


def output_text(row):
    for key in ("inserted", "output", "modelOutput", "afterDeterministic"):
        value = row.get(key)
        if value is not None:
            return value, key
    return None, None


def stage_of(span, row, kind="span"):
    """Where the span (or a negation) first went missing, if the row carries the stages."""
    raw, det, model = row.get("asrRaw"), row.get("afterDeterministic"), row.get("modelOutput")
    measure = (lambda t: count(span, t)) if kind == "span" else negations
    if det is not None and measure(det) != measure(raw):
        return "deterministic"
    if model is not None and det is not None and measure(model) != measure(det):
        return "model"
    return "final"


def label_for(span, text_in, text_out):
    low = norm(span).lower()
    partners = ([CONTRACTIONS[low]] if low in CONTRACTIONS else []) + EXPANSIONS.get(low, [])
    for partner in partners:
        if count(partner, text_out) > count(partner, text_in):
            return "contraction", partner
    if re.search(r"\d", span):
        key = digits_key(span)
        for candidate in number_candidates(text_out):
            if digits_key(candidate) == key and count(candidate, text_out) > count(candidate, text_in):
                return "format-only", candidate
    return "content", "absent"


def score(annotations, outputs):
    result = {
        "rows": 0, "rows_with_output": 0, "present": 0, "mutated": 0, "case_drift": 0,
        "by_label": Counter(), "by_stage": Counter(), "mutations": [], "asr_misses": OrderedDict(),
        "missing_output_rows": [], "model_reasons": Counter(), "rows_sent_to_model": 0,
        "retraction_rows": 0, "retracted_total": 0, "retracted_heard": 0, "retracted_survived": 0,
        "corrected_total": 0, "corrected_present": 0, "handled_correctly": 0, "retractions": [],
    }
    for ann in annotations:
        result["rows"] += 1
        row = outputs.get(ann["id"])
        if row is None:
            result["missing_output_rows"].append(ann["id"])
            continue
        text_in = row.get("asrRaw")
        if text_in is None:
            result["missing_output_rows"].append(ann["id"] + " (no asrRaw)")
            continue
        text_out, out_key = output_text(row)
        result["rows_with_output"] += 1
        reason = row.get("modelReason", "")
        result["model_reasons"][reason] += 1
        if reason and not (reason == "gated" or reason.startswith("skipped")):
            result["rows_sent_to_model"] += 1
        row_mutations = []
        for span in ann.get("protected_spans", []):
            n_in = count(span, text_in)
            if n_in == 0:
                result["asr_misses"].setdefault(ann["id"], []).append(span)
                continue
            result["present"] += 1
            n_out = count(span, text_out)
            if n_out < n_in:
                result["mutated"] += 1
                label, after = label_for(span, text_in, text_out)
                stage = stage_of(span, row)
                result["by_label"][label] += 1
                result["by_stage"][stage] += 1
                row_mutations.append({"span": span, "label": label, "before": span, "after": after,
                                      "count_in": n_in, "count_out": n_out, "stage": stage})
            elif count(span, text_out, True) < count(span, text_in, True):
                result["case_drift"] += 1
        neg_in, neg_out = negations(text_in), negations(text_out)
        if neg_in != neg_out:
            label = "negation added" if neg_out > neg_in else "negation dropped"
            stage = stage_of(None, row, kind="negation")
            result["mutated"] += 1
            result["present"] += 1
            result["by_label"][label] += 1
            result["by_stage"][stage] += 1
            row_mutations.append({"span": "(negation count)", "label": label,
                                  "before": str(neg_in), "after": str(neg_out), "stage": stage})
        if row_mutations:
            result["mutations"].append({"id": ann["id"], "input": text_in, "output": text_out,
                                        "output_field": out_key, "modelReason": reason,
                                        "mutations": row_mutations})
        retracted, corrected = ann.get("retracted", []), ann.get("corrected", [])
        if retracted or corrected:
            result["retraction_rows"] += 1
            heard = [v for v in retracted if count(v, text_in) > 0]
            survived = [v for v in retracted if count(v, text_out) > 0]
            present = [v for v in corrected if count(v, text_out) > 0]
            result["retracted_total"] += len(retracted)
            result["retracted_heard"] += len(heard)
            result["retracted_survived"] += len(survived)
            result["corrected_total"] += len(corrected)
            result["corrected_present"] += len(present)
            ok = len(present) == len(corrected) and not survived
            if ok:
                result["handled_correctly"] += 1
            result["retractions"].append({"id": ann["id"], "retracted": retracted, "heard": heard,
                                          "survived": survived, "corrected": corrected,
                                          "corrected_present": present, "handled": ok, "output": text_out})
    result["rate"] = (result["mutated"] / result["present"]) if result["present"] else 0.0
    return result


def load_outputs(path):
    rows = OrderedDict()
    meta = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("kind") == "meta":
                meta = row
                continue
            if row.get("kind") == "hearing" or "id" not in row:
                continue
            if row.get("kind") == "shadow":
                # The shadow run's reply, appended after its row: the model's
                # output, reason, chunk reasons and own time become the row's.
                target = rows.get(row["id"])
                if target is not None:
                    for key in ("modelOutput", "modelReason", "modelChunks", "polishSeconds",
                                "polishColdStart", "secondsSinceLastPolish"):
                        if key in row:
                            target[key] = row[key]
                    target["shadow"] = True
                continue
            rows[row["id"]] = row
    return rows, meta


def selftest():
    """The rules on hand-made cases; `span-score.py --selftest`."""
    assert count("Sara", "Email Sarah about it, not Sarah.") == 0
    assert count("not", "nothing is not here") == 1
    assert count("swift", "The file is TextInjector.swift") == 1
    assert count("Do not", "do not deploy") == 1 and count("Do not", "do not deploy", True) == 0
    assert count("$99", "It costs $9.99 a month, not $99.") == 1
    assert negations("I can't do it, cannot, never, without, no") == 5
    assert label_for("can't", "I can't make it", "I cannot make it") == ("contraction", "cannot")
    assert label_for("do not", "do not deploy", "don't deploy") == ("contraction", "don't")
    assert label_for("$1,200", "was $1,200", "was $1200") == ("format-only", "$1200")
    assert label_for("Monday", "until Monday", "until Tuesday") == ("content", "absent")
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(json.dumps({"id": "S", "asrRaw": "send it", "afterDeterministic": "Send it.", "modelOutput": None,
                            "modelReason": "shadow:pending", "inserted": "Send it.", "polishSeconds": 0}) + "\n")
        f.write(json.dumps({"id": "S", "kind": "shadow", "modelOutput": "Send it.", "modelReason": "landed",
                            "modelChunks": ["landed"], "polishSeconds": 0.6}) + "\n")
        f.write(json.dumps({"id": "S", "kind": "hearing", "decision": "unchanged"}) + "\n")
    merged, _ = load_outputs(f.name)
    assert merged["S"]["modelReason"] == "landed" and merged["S"]["polishSeconds"] == 0.6 and merged["S"]["shadow"]
    assert merged["S"]["inserted"] == "Send it."   # the words that landed are untouched by the merge
    fann = [{"id": "F", "protected_spans": ["Wednesday"], "corrected": ["Wednesday"], "retracted": ["Tuesday"]}]
    fout = {"F": {"asrRaw": "send it Tuesday, no, Wednesday", "inserted": "Send it Tuesday, no, Wednesday."}}
    fr = score(fann, fout)
    assert fr["retraction_rows"] == 1 and fr["retracted_heard"] == 1 and fr["retracted_survived"] == 1
    assert fr["corrected_present"] == 1 and fr["handled_correctly"] == 0 and fr["mutated"] == 0
    fout["F"]["inserted"] = "Send it Wednesday."
    fr = score(fann, fout)
    assert fr["retracted_survived"] == 0 and fr["handled_correctly"] == 1
    # Under rule 5 the marker "no" is a negation token, so a repair that
    # removes it reads as "negation dropped" (1 mutation). Stated here so the
    # founder's decision on the marker is taken with the number in view.
    assert fr["mutated"] == 1 and fr["by_label"] == {"negation dropped": 1}
    ann = [{"id": "X", "protected_spans": ["Do not", "Monday", "$1,200"]}]
    out = {"X": {"asrRaw": "Do not ship until Monday, it was $1200",
                 "afterDeterministic": "Do not ship until Monday, it was $1200",
                 "modelOutput": "don't ship until Monday, it was $1200",
                 "inserted": "don't ship until Monday, it was $1200"}}
    r = score(ann, out)
    assert r["present"] == 2 and r["mutated"] == 1 and r["asr_misses"] == {"X": ["$1,200"]}
    assert r["by_label"] == {"contraction": 1} and r["by_stage"] == {"model": 1}
    print("span-score selftest: ok")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        annotations = json.load(f)
    outputs, meta = load_outputs(sys.argv[2])
    result = score(annotations, outputs)
    if "--json" in sys.argv:
        result["by_label"] = dict(result["by_label"])
        result["by_stage"] = dict(result["by_stage"])
        result["model_reasons"] = dict(result["model_reasons"])
        result["meta"] = meta
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return
    if meta:
        print(f"run: {meta.get('label') or meta.get('tool')}  commit {meta.get('commit')}  "
              f"prompt {str(meta.get('promptPlainSHA256'))[:12]}  model {meta.get('modelAsset')} {meta.get('modelVersion')}  "
              f"gated={meta.get('gated')}")
    print(f"rows: {result['rows']} annotated, {result['rows_with_output']} with an output row"
          + (f", MISSING OUTPUT FOR: {result['missing_output_rows']}" if result["missing_output_rows"] else ""))
    print(f"rows sent to the model: {result['rows_sent_to_model']}  (modelReason: {dict(result['model_reasons'])})")
    print(f"spans present: {result['present']}")
    print(f"spans mutated: {result['mutated']}")
    print(f"mutation rate: {result['rate']:.4f}  ({result['mutated']}/{result['present']})")
    print("by label: " + (", ".join(f"{k} {v}" for k, v in sorted(result["by_label"].items())) or "none"))
    print("by stage: " + (", ".join(f"{k} {v}" for k, v in sorted(result["by_stage"].items())) or "none"))
    print(f"case drift (not in the rate): {result['case_drift']}")
    if result["retraction_rows"]:
        print(f"self-corrections (not in the rate): {result['retraction_rows']} rows; "
              f"retracted values {result['retracted_total']}, heard by the ASR {result['retracted_heard']}, "
              f"SURVIVED into the output {result['retracted_survived']}; corrected values present "
              f"{result['corrected_present']} of {result['corrected_total']}; rows handled correctly "
              f"{result['handled_correctly']} of {result['retraction_rows']}")
        for entry in result["retractions"]:
            if not entry["handled"]:
                print(f"  {entry['id']}: retracted {entry['retracted']} survived {entry['survived']}; "
                      f"corrected {entry['corrected']} present {entry['corrected_present']} | {entry['output']}")
    print("ASR misses (spans absent from asrRaw; not cleanup findings):")
    if result["asr_misses"]:
        for rid, spans in result["asr_misses"].items():
            print(f"  {rid}: {spans}")
    else:
        print("  none")
    print("mutations by row:")
    if not result["mutations"]:
        print("  none")
    for entry in result["mutations"]:
        print(f"  {entry['id']} [{entry['modelReason']}; scored {entry['output_field']}]")
        print(f"    in : {entry['input']}")
        print(f"    out: {entry['output']}")
        for m in entry["mutations"]:
            print(f"    - {m['label']} @{m['stage']}: {m['before']!r} -> {m['after']!r}")


if __name__ == "__main__":
    main()
