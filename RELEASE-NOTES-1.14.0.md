# Chalant 1.14.0

It learns your names.

## Fix it twice and it stops getting it wrong

Dictate a name your Mac has never heard of and it will guess. Say
"Chalant" and you might get "Chalan". Say a surname and you might get
something close but not yours.

Fix it, the way you already would, by typing over it. Do that twice and
Chalant stops making that mistake. No settings, no dictionary to fill
in, no telling it anything.

Everything it has worked out is listed in Settings, General, Dictation,
under "Learn my names". A wrong word on the left, your word on the
right, and an x to delete any row you disagree with. Deleted stays
deleted.

## What it keeps

The pair of words. Not the sentence they were in, not the document, not
which app you were in. A wrong word and a right word, in a file on your
Mac you can read and delete.

It is watching the text field it just wrote to, for about twenty
seconds, and only after it actually put something there. If you leave
the text alone it learns nothing and forgets it was looking.

## The careful part

Changing your mind is not a correction, and Chalant has to tell the
difference or it would learn nonsense.

"Chalan" becoming "Chalant" is a correction: they sound alike, so it
plausibly misheard you. "Tuesday" becoming "Wednesday" is not: nobody
mishears one as the other, you simply changed your mind. It only learns
when the two words sound like each other, when exactly one word
changed, and when neither of them is a number or a small connecting
word.

It would rather learn nothing than learn something wrong, because a
wrong lesson is not one bad sentence, it is every sentence after.

## Names your Mac breaks in half

Separately from learning, Chalant now puts back together the names that
arrive in pieces. "Friction lens" becomes "FrictionLens", "app cast"
becomes "appcast", "speech analyzer" becomes "SpeechAnalyzer". It only
does this for words it knows are yours.

## Two honest limits

**It cannot see corrections everywhere.** Some apps do not let another
app read the text you are typing. Chalant will learn from the ones that
do and quietly learn nothing from the rest. Which is which is not
something anyone can list up front.

**It needs to see the same fix twice.** Once could be a typo, or you
rewriting a sentence for a reason that has nothing to do with what you
said. Twice is the smallest number that means something.

## Smaller things

Chalant now knows how certain it was about each word it heard, which it
did not before, and uses that to decide when it is allowed to correct
itself and when it should leave your words alone.

You can turn all of this off in the same place you turn it on.
