# Set C, the semantic torture set, with protected spans

**What this set measures.** The protected-span mutation rate of the text path
that runs after ASR: the deterministic pipeline and the on-device cleanup.
`STAGE1_DIRECTIVE.md` §4.1 sets its target at zero and calls any other value
"the single most important bug in the product". Until 2026-08-21 nothing in
the repo could produce the number: the manifests had no `protected_spans`
field, no scorer knew the concept, and the raw ASR text was never kept.

## The files

- `setC.json`: the 30 utterances in the directive's §2.3 format. `truth` is
  the founder's ground truth as recorded (the `desired` field of
  `~/Desktop/chalant-corpus/manifest.jsonl`). `protected_spans` are exact
  substrings of `truth`, approved by the founder on 2026-08-21 (Task 1 review).
  `audio` points at the recordings, which stay on the Desktop (52 MB, the
  founder's voice); the text test needs none of it.
- `setC-asr-en_US.jsonl`: one line per row, `{"id", "raw"}`, the raw Apple
  `SpeechTranscriber` output for each clip at locale en-US, copied verbatim
  from `~/Desktop/chalant-corpus/manifest.en_US.jsonl` (produced 2026-08-15
  16:16 by `runlocales.py` over `./transcribe`, macOS 27.0 26A5378n). **This
  is the input to the scorer and it is never corrected**: what the ASR got
  wrong is an ASR finding, reported separately, and out of this set's scope.

## What a protected span is

A substring of the truth whose alteration changes meaning. The category list
(numbers, times, currency, dates, negations, names, paths, emails,
identifiers) is illustrative; the founder's rulings on 2026-08-21 extend it:

- Operations are protected ("deploy", "Delete", "Drop", "merge", "cancel",
  "Revoke", "overwrite", "force push").
- Pronouns and scope words are protected where the sentence turns on them
  ("his", "hers", "only", "yet", "anyone else", "a month").
- Meta-instructions are NOT protected ("and I quote", "dot", "capital T
  capital I"): the invariant protects what the user means, not how they said
  it, and a future code mode must be free to render "dot swift" as ".swift".
- An absence is not a span. C09, C20 and C26 are carried by the negation
  count rule below.

## How the scorer reads them (rules fixed by the founder, 2026-08-21)

1. Presence and mutation compare case-insensitively. Case drift (present in
   both, differing in case) is reported as its own count and does not feed
   the rate.
2. A contraction or expansion ("do not" to "don't") is a mutation, labelled
   `contraction`.
3. Numbers are verbatim, never normalised. A mutation whose digits match after
   stripping commas, spaces and currency symbols is labelled `format-only`.
   Both labels feed the rate.
4. Whole-word matching at boundaries (start or end of text, whitespace,
   punctuation). A span is present if it occurs at least once in the input;
   mutated if its count in the output is lower than in the input.
5. Negation tokens (not, no, never, n't as a suffix, without, nor) are counted
   in input and output per row; any difference is a mutation, labelled
   `negation added` or `negation dropped`.

Mutation rate = mutated / present, across all rows. Spans absent from the raw
ASR are ASR misses, listed by row, never counted as mutations.

## Reproducing the number

```bash
Dictation/tools/textpath/build.sh          # Core as a module + the shipping polisher
cd Dictation
./build/tools/textpath corpus/setC-asr-en_US.jsonl corpus/runs/setC-gated.jsonl --label "setC gated"
./build/tools/textpath corpus/setC-asr-en_US.jsonl corpus/runs/setC-ungated-1.jsonl --ungated --label "setC ungated pass 1"
python3 corpus-kit/span-score.py corpus/setC.json corpus/runs/setC-gated.jsonl
python3 corpus-kit/span-score.py --selftest
```

`textpath` runs the controller's path (empty vocabulary, no release budget)
and writes schema-3 rows with a first-line stamp: commit, SHA-256 of the
prompt, the model asset and version the daemon loaded. **Runs under
different stamps are different experiments and are never averaged.** The
saved runs in `corpus/runs/` are the first measurement (2026-08-21); the
scorer reads the same field names off `captured.jsonl`, so the number can
be taken off real dictations with an annotations file keyed by row id.

`setD-asr-en_US.jsonl` (from `manifest.en_US.jsonl`) and `setE-asr-en_US.jsonl`
(from `build/harness/ear/apple-E.tsv`, the Apple en-US transcripts of the Set E
clips made 2026-08-18) are the false-rejection inputs for guard rules; the
`*-rule6-*` run files in `corpus/runs/` are their first use (2026-08-22).
