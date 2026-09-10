# Chalant 1.40.0

The right words the first time, and an app that does not quietly disappear.

## Both ears agree before your words land

Chalant has always had a second, more careful ear. Until now it only ever
spoke up after your words had already arrived, so its corrections showed up a
second or two late, or in apps with no safe undo they were worked out and then
thrown away. Over one week of real use that was 57 corrections computed and
binned.

Now both ears listen to the same sentence and settle it before anything is
typed. One clean version lands.

What that means in practice, taken from real dictations that used to go wrong:
"a recruiter" no longer arrives as "agriculture", "commas" no longer as
"commerce", "the option button" no longer as "the auction button". A sentence
where you said "I don't want the box" no longer lands as "I want the box".

The trade is a short wait when the two ears disagree. When they agree, which is
most of the time, nothing changes.

## It knows when to leave your words alone

The careful ear does not get to win every argument. It cannot invent a word,
overrule a confident hearing, change a number, touch a name you have taught
Chalant, or quietly swap one small connecting word for another. Those limits
were not guesses: forty of your own recordings were played back and judged by
ear, and the rules were set by what actually sounded right.

## A name is learned the first time it is heard

A name comes out differently wrong every time, so waiting to see the same
mistake twice meant waiting for something that never happened. When Chalant
writes something that is not a word and the careful ear hears a real one, it
learns it there and then.

## It comes back when macOS stops it

macOS stops background apps when memory runs short, and it had started doing
that to Chalant. There is no crash, no warning, and nothing on screen to show
it happened: you press the key and nothing occurs.

Chalant now returns on its own when the system stops it. Quitting it yourself
still quits it, and it stays quit.

## It rests when you are not using it

After a long silence Chalant puts its speech model down and picks it up again
the next time you dictate. It uses far less memory while it sits idle, which is
what made the system reach for it in the first place. The first thing you say
after a long gap lands without the second ear, and everything after that has it
back.

## Under the hood

Chalant now refuses to run twice. Two copies would both answer the dictation
key and both paste, which is where doubled text came from.
