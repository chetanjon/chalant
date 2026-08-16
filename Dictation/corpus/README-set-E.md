# Set E, the `propernoun` set

**Why this set exists, and why it is the blocking one.** The whole vocabulary
and learning layer (M4, M5) is accepted on one number: *"`propernoun` corrections
per 100 words drops at least 30% versus baseline, and precision does not fall."*

**The corpus cannot currently produce that number.** The locked English set
contains **2 proper-noun errors in 225 words**. On 2026-08-15 the vocabulary
pass was swept across a full grid of thresholds and the entire result rested on
1 win and 1 loss, which is noise with a table around it. No threshold may be
tuned on that, and no decision about the moat should be taken from it.

This set is 30 utterances that are nothing but the founder's real vocabulary.

## Recording it

Same harness as sets C and D, in `~/Desktop/chalant-corpus`:

```bash
cd ~/Desktop/chalant-corpus
cp /path/to/moai/Dictation/corpus/prompts-E.tsv .
SECS=8 ./voiceprobe ./audio-E prompts-E.tsv
python3 add-E.py            # appends the 30 rows to manifest.jsonl
```

**Lid OPEN and the built-in microphone.** With the lid closed this Mac's
built-in mic delivers exactly zero: a corpus recorded that way is 30 files of
digital silence, and it has already happened once.

**Do not re-record a fumbled take.** A fumble is a data point. Deleting the
messy ones is how a corpus ends up flattering the thing it is supposed to test.

**Do not over-enunciate.** Read them the way you would say them at four in the
afternoon, not the way you would read them to a microphone.

## Why the sentences look like this

- **Every sentence is written so that what you SAY is exactly what should be
  INSERTED.** No spoken numbers, no `snake_case`, no file paths. That makes the
  ground truth free and unarguable, and it isolates the vocabulary question from
  the number-formatting question, which is a different and already-measured
  problem.
- **Near-miss pairs appear on purpose.** `Sarah` and `Sara` are in four
  sentences, sometimes together. The locked set caught `not Sara` collapsing
  into `not Sarah` on its very first run, and that collapse is the single
  clearest example of a meaning-changing error a vocabulary layer must fix
  without introducing its own.
- **Competitor names are in it** (`Wispr Flow`, `Superwhisper`, `Willow`,
  `Whisper`) because they are said constantly in this project's own work and
  they came back as `Whisper Fluence Super Whisper` in real dictation.
- **The founder's own surname is in it twice**, once inside an email address.
  `jonnalagadda8800@gmail.com` came back as `Junalagadda 8800@gmail.com`.

## What is deliberately NOT here

**The `technical` set** (identifiers, `snake_case`, `git rebase -i`,
`TextInjector.swift`) is not included. It measures M6 code mode, which is not
built and is not next. Recording it now would produce a number nothing can act
on. It should be recorded when M6 starts.
