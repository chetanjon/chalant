# Chalant 1.14.1

A fix for the tidying, found within minutes of 1.14.0 going out.

## Long dictation was not being tidied

Dictate a long paragraph on 1.14.0 and you got it back untidied, as if the
feature had done nothing. It had done something. It had produced a good
cleaned version, and Chalant then threw that version away.

The tidying has a guard behind it that rejects a result the model has
mangled, and one of the things it watches for is the model repeating
itself. It was watching too broadly: any short phrase that appeared twice
in the output counted, and in a long paragraph ordinary English does that
all the time. "He will" twice in five hundred words is a person talking,
not a machine stuttering. Short sentences never had room to repeat a
phrase, which is why this only showed up on the long ones, which is exactly
where the tidying is worth waiting for.

It now counts a repeat only when the two halves sit close together, which
is what a real stutter looks like.

## Being honest about what is left

On long paragraphs the tidying is still not something to trust blindly.
Run the same paragraph a few times and the model will sometimes drop a
"not", or invent a half sentence, or start talking about you in the third
person. The guard catches the first two and hands you your own words
instead. It cannot yet see the third.

Short sentences are in good shape. Long ones are better than 1.14.0 and
not yet where they should be.
