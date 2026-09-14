# engineprobe

Three recognizers, the same recordings, the same scorer.

```
swift build -c release --package-path Dictation/tools/engineprobe
.build/release/engineprobe <manifest.jsonl|dir> <out.jsonl> --engine apple|parakeet|whisper
      [--aggregation min|max|mean] [--limit N] [--deep] [--tokens]
```

Writes one JSON object per line: `{id, audio, raw, seconds, engine}`, plus
`deep` with `--deep` (the shipping deterministic chain, empty vocabulary) and
`detail: [{t, c}]` with `--tokens` (per-word text and confidence, for sweeping
thresholds offline without decoding again).

Scored with the kit that already exists, so the numbers are comparable to
every number in `EVAL-LOG.md`:

```
python3 Dictation/corpus-kit/score.py <manifest-with-output.jsonl> \
    --terms ~/Desktop/chalant-corpus/terms-canonical.txt --split dev
```

**`--engine whisper` loads a 606 MB model and `--engine parakeet` a 471 MB
one.** Both are the same files the app uses, in the same places, so a machine
that has used the feature has them already.

The discipline is `tools/transcribe`'s and `tools/mergeprobe`'s: decode once,
write the tokens to disk, sweep offline. Re-decoding audio to move a threshold
is how threshold work becomes unaffordable.
