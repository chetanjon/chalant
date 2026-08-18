# Chalant 1.20.0

Better hearing.

## A second ear, when you want it

Settings, General, Dictation now has a switch called Better hearing. Off, it
does nothing and downloads nothing. On, Chalant fetches a stronger speech model
once (606 MB, kept on this Mac, nothing leaves it) and from then on a second
ear listens to what you said after your words land. When it heard better,
the words are corrected in place a second or two later: the name you actually
said, the number, the word the first ear guessed at.

Same rules as every correction Chalant makes in place: not if you have started
typing, not in terminals or editors that carry one. It uses memory while it is
loaded and a little more battery per sentence, which is why it is a switch.

Measured on the founder's own voice before it shipped: about half the
recognition errors of the built-in ear on the sentences that matter, names
included.
