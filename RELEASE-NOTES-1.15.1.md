# Chalant 1.15.1

Dictation survives your microphones changing.

## Plug in, unplug, connect, disconnect: it keeps listening

Plug in wired earphones, pull them out, connect a Bluetooth headset or a
speaker with a mic, let it disconnect. Before, any one of those could
leave dictation deaf until you relaunched Chalant: you held the key, the
strip opened, and nothing you said arrived. Now the ear rebuilds itself
within about a tenth of a second of the change, and if it ever misses that,
it notices within two seconds and rebuilds anyway.

## A hold never lands on a dead ear

If you press the key at the exact moment a microphone change is still
settling, Chalant rebuilds the ear before it starts capturing, so the
sentence you are about to say is not lost to a bad moment.

## And it cannot take the app down with it

One of the ways an audio device can misreport its format used to be able
to end Chalant outright while it was recovering. It cannot any more.

## For the curious

The three watchers are independent, because the system is not consistent
about which change it announces and which it does not: one listens for the
announcement, one watches whether audio is actually arriving, and one
checks at the moment you press the key.
