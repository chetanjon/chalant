# Chalant 1.19.0

Refined at once.

## Tidied words, the moment you let go

Chalant now tidies what you are saying while you are still saying it. When you
release Option, the cleaned text lands right away if the tidying is done, and
otherwise about half a second later, once, already tidied. No raw text first,
no swap. If the last words are still being worked on past that half second,
they land as said and are tidied in place a moment later, as before.

## Lists, instantly

"Three things: first… second… third" lands as bullets the moment you let go.
"Number one, number two, number three" lands numbered. Only when you say it
that way: three or more, in order. "The first draft" stays a sentence.

## Under the hood

The on-device tidy reads a shorter brief unless it sees a list, which is what
makes the last few words cost under half a second.
