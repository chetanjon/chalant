# Chalant 1.13.0

Hold left Option anywhere and talk. Your words land where you were
already typing, in whatever app you were already in.

## Dictation, in the same app

It used to be a separate build. It is not any more.

Hold the left Option key, say something, let go. The text arrives at
your cursor, in Slack, in a browser, in your editor, wherever the caret
was when you pressed the key. Nothing to open, nothing to click.

The transcription happens on this Mac. No account, no upload, no
network. On this machine it takes about a tenth of a second from
letting go of the key to seeing the words.

## It is off until you switch it on

Settings, General, Dictation.

That is deliberate. Turning it on is what asks macOS for Input
Monitoring and Accessibility, and nobody who updated Chalant this week
asked to be handed two permission prompts. One lets it notice the key,
the other lets it place the text. The switch explains both before
either appears.

Needs macOS 26 for the on-device speech model. The rest of Chalant does
not, and the settings card says so rather than hiding.

## One microphone, decided once

Chalant and dictation used to each pick their own microphone, with
their own idea of what a dead one looked like. In August the same
failure had to be found and fixed twice, once in each, because neither
could see the other.

They share one now. It also remembers: an input caught delivering
silence goes to the back of the queue and stays there, so a lid-closed
built-in mic no longer costs you the first second and a half of every
sentence while the app works out again that it cannot hear.

Two consequences worth naming. The Mac's own microphone now outranks
whatever macOS most recently made the default, because connecting
AirPods changes that default without anyone choosing it; pin the one
you want in Settings and the pin still wins. And Chalant now needs
macOS 15, up from 14. The shared microphone layer cannot be built on 14
without putting a lock in the audio path, which is the one thing that
must never happen there.

## Smaller things

The permission prompts now describe the app they belong to. One of them
promised Chalant controlled your music players "and nothing more",
which stopped being true the moment dictation could paste into any app.

Text that is not text no longer reaches your document. One utterance
produced seven words and forty-one commas; that gets trimmed now.

Stutters get collapsed. "The the deadline" becomes "The deadline". Only
exact repetitions, and never where the repetition is real: "he had had
enough" survives, and so does any repeated number.

The noises nobody means to say are removed. "Uh" and "um" always. "You
know" and "I mean" only where you paused on both sides of them, which
is how you can tell an aside from a question: "Do you know, Sarah?"
keeps its words.

"Like" is the careful one. It goes when a comma follows it and stays
otherwise, because three times out of four it is doing real work in the
sentence. "Something like a name" is not a filler, and neither is "like
PostHog or ElevenLabs".
