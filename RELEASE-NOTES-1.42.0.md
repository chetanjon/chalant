# Chalant 1.42.0

You pick the ear, you pick the key, and nothing you say disappears without
being told where it went.

## One ear instead of two, and it is yours to choose

Until now Chalant ran a second, careful ear alongside the first and made them
agree before your words landed. It found real mistakes. It also made you wait:
on the two dictations there is a measurement for, the pause between letting go
and seeing words was about three and a half seconds, against under half a
second on the build before. And on nearly half of sentences the two ears wrote
exactly the same thing, so nearly half of that waiting bought nothing.

So the second ear is a choice now rather than something running behind every
sentence. Settings has a **Recognizer** picker with three, and each says what it
costs:

- **Apple** is macOS's own. Nothing to download, and it starts instantly.
- **Parakeet** is a stronger model that runs on this Mac. About 470 MB once.
- **Whisper** is the ear Chalant used to run second. About 606 MB once. It is
  the only one that can be told your names before it listens, and the slowest
  of the three by about three quarters of a second a sentence.

If you had **Better hearing** switched on, you are on Whisper: that is the
model you chose and downloaded, and it did not seem right to move you off it
without asking. If it feels slow now, Apple is one click away and there is
nothing to download.

**Apple is the default on a fresh install, and that was a measurement rather
than a preference.** All three were run over sixty recordings of real speech
with known correct text, and on this voice Apple needed fewer corrections than
Parakeet and needs no download. Whisper needed the fewest of all, and takes
about six times as long per sentence to do it. Your voice is not that voice, so
the picker is there.

Numbers written the way you say them now come out the way you meant them on
Parakeet: "one hundred and twenty dollars" becomes $120, "three fifteen"
becomes 3:15.

## Option and the arrow keys stop starting a dictation

This one had been there a long time. Option+arrow moves the cursor by word,
Option+Delete deletes a word, Option+e starts an accented character, and every
one of them is a press of the same key you hold to talk. So every one of them
lit the strip, woke the microphone, and **paused whatever you were listening
to**, then undid it a moment later.

Now pressing any other key while the hold key is down means you wanted that
shortcut. Chalant stands down, types nothing, and says nothing. And nothing is
shown, paused or loaded at all until the key has been held long enough to mean
something, so a shortcut costs you nothing on the way past. Your microphone
still starts recording at the instant you press, so speaking immediately still
works.

If it is still in the way, **the key can move**. Settings offers Right Option,
Right Command, Right Control and Fn as well.

## Nothing vanishes in silence

There were four ways a dictation could end with nothing typed, nothing on your
clipboard, and nothing said. The commonest was the worst: you spoke, the light
went out, and nothing happened, which is indistinguishable from the app being
broken.

- Nothing heard now says so, and says which kind of silence it was: it did not
  catch you, or your microphone itself heard nothing and which one it is.
- **Switching app before letting go** used to lose the sentence outright. Your
  words go to the clipboard, you are told, and there is a **Retry** that types
  them into wherever you have moved to.
- When words cannot be typed, you get the reason, a copy button and that same
  retry, instead of one clipped line in the corner.

## The light waits with you

The strip used to disappear the moment you let go, while everything after that
happened in the dark. Now it goes still and dim until your words are actually
somewhere. It does not spin, travel or announce itself.

## "New paragraph" works

Saying "new paragraph" or "new line" has always been understood by the optional
rewriting pass, which most people have switched off, so most of the time it
typed the words "new paragraph" into your document. It is a plain rule now and
works whatever your rewriting setting is. Sentences about text are safe: "add a
new line to the file" still says exactly that.

## Under the hood

Chalant now checks that a paste actually arrived where apps will tell it, and
never pastes twice when it cannot be sure, so text can no longer be doubled by
a retry. Restoring your clipboard after a dictation no longer overwrites
something you copied in the meantime. And the on-device rewriting model is no
longer loaded on every keypress in a mode that was never going to call it.

## Still true

Everything you say is turned into text on this Mac. Nothing is uploaded, no
account, no keys. The models download once, from Apple and from Hugging Face,
and then never again.
