# Chalant 1.16.1

Short things land faster.

## Under a sentence, no waiting

Cleanup now runs only on dictation longer than about forty characters. A
command, a reply, a "send it" or a "what next" lands the moment you let go,
about a fifth of a second, because on short dictation the cleanup had
nothing useful to add and half a second to cost. Full sentences and
paragraphs are cleaned exactly as before.

Measured on a day of the founder's real dictation: the typical wait from
letting go to text on screen goes from about 0.9 seconds to about 0.35, and
of the twenty-two things the cleanup fixed that day, twenty are on sentences
long enough to still be cleaned.

## One stray line, gone

In rare cases the cleanup could append a line reading "TRANSCRIPT." to what
you said. It cannot any more.
