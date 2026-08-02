# Ambience quality: synthesize the textures

2026-08-02. Approved by the user the same day.

## The complaint

"I think the noises need to be of high quality." Asked what they were hearing,
the user picked every symptom offered: it loops, it is thin and small, it is
muffled and dull, and it sounds fake or watery.

## What is actually wrong today

Measured, not guessed:

- **The sources are free amateur recordings.** rain (Wikimedia, CC BY-SA 4.0),
  cafe (Wikimedia, CC0), fire (Wikimedia, CC BY 3.0), all encoded at roughly
  128 kbps AAC. Noise-like material is the worst case for AAC, and its
  artifacts read as watery.
- **fire is 60 seconds and mono.** No width, and a crackle texture makes
  repetition obvious faster than any other sound in the set.
- **Only the first 120 seconds of any recording is loaded**, then looped with
  `scheduleBuffer(.loops)`, which is a hard splice. There is a seam every cycle.
- **The recordings are time-stretched to hide their flaws.** cafe runs at 0.78x,
  rain at 0.9x with a 250 cent drop. Stretching smears transients, which is the
  single most likely source of the processed character.
- **The corrective EQ is steep.** rain is cut at 5.5 kHz, cafe at 3 kHz, brown
  is lowpassed at 1.4 kHz. Warm, but the same filters are what make it dull.
- **The synthesized colors are dual mono.** `nextSample()` is computed once per
  frame and written identically to every channel, so brown, pink and white
  collapse to a point in the middle of the listener's head.

The through-line: mediocre source material, repaired in code. The repairs are
what sound like repairs.

## The decision

Synthesize the textures instead of repairing recordings.

- **rain and fire become real-time generators**, the way brown and pink already
  are. They never repeat, never seam, are stereo by construction, have no codec,
  and their brightness becomes a parameter rather than a lowpass hiding a flaw.
  Roughly 6 MB leaves the app with the two files.
- **cafe stays a recording**, rehabilitated: full length, 1.0x rate, no pitch
  shift, crossfaded loop seam, gentler EQ. A believable room full of people is
  the one thing synthesis does badly. If the rehabilitated file cannot hold its
  own next to the new generators, re-sourcing it is the fallback, decided by ear.
- **brown, pink and white go true stereo** and lose some of the blanket.

**Character does not change.** The user chose "same character, better made":
rain stays soft and distant, fire stays a hearth heard from across the room,
cafe stays a far corner. This is a fidelity change, not a re-voicing.

## Architecture

`NoiseEngine` is about 560 lines doing filter design, voicings, the file chain,
transport, and the render callback at once. The generators cannot be tested
because they are welded to an audio device.

Split along that seam:

- **`Soundscape`** is a protocol with one job: `render(left:right:frames:)`,
  filling two channel buffers with the next block of audio. Implementations hold
  their own per-channel state and know nothing about AVAudioEngine.
- **One type per sound**: `BrownNoise`, `PinkNoise`, `WhiteNoise`, `RainScape`,
  `FireScape`. Each is understandable on its own and changeable without touching
  the others.
- **`NoiseEngine` keeps transport**: engine lifecycle, gain ramps, fades, the
  cafe file chain, and the source node that asks the current soundscape for
  samples. It stops owning any generator's internals.

The point of the split is not tidiness. It is that a `Soundscape` can be
rendered into a plain buffer with no audio hardware, which is what makes the
verification below possible at all.

## How rain and fire are made

**Rain.** Two decorrelated noise beds, a low street-hiss band and a mid band,
each drifting slowly in level so the texture breathes instead of sitting still.
Over that, droplet events at a Poisson rate: short resonant pings bandpassed
between 800 Hz and 3 kHz with 15 to 60 ms decays, each randomly panned and
randomly damped. The droplet rate stays low and the top end is shelved rather
than cliffed at 5.5 kHz, which keeps today's soft, distant character without
the mud.

**Fire.** A low rumble bed with slow drift, plus crackle events that arrive in
flurries rather than evenly, because real fires crackle in bursts. Each crackle
is a very short exponentially decaying transient in the 1.5 to 4 kHz band, with
rare larger pops scattered among them. The low end is shaped at generation
rather than cut afterwards by a shelf.

Both are stereo by construction: independent noise and independent event streams
per channel. The width is real, not a widener smeared over a mono source.

## Verification

**Offline first.** A render harness produces N seconds from any `Soundscape`
into a buffer with no audio device. That turns qualities normally left to vibes
into assertions the suite can hold:

- no DC offset
- no clipping
- RMS inside a target band, so the sounds match each other in loudness
- spectral tilt inside the expected range per sound (brown falls, pink falls
  less, rain and fire sit where their voicings say)
- left/right correlation below a threshold, which is the actual proof that
  stereo is real
- no silent gaps, which is the failure mode a sparse event generator has

**Then ears.** 30-second renders of each soundscape go to the user to audition.
Nothing ships until they say it sounds right. Character is theirs to judge;
the suite only holds the floor.

**Then cost.** CPU measured with the heaviest scape running, held near 1% of a
core, consistent with the audited idle baseline the app already defends.

## What does not change

The five chips and their names, the volume slider, quiet-by-default behavior,
the honest failure line when a sound cannot be made, and the rule from 1.3.6
that a focus session never touches ambience.

One side effect: the README attributions shrink to cafe alone, and the CC BY-SA
share-alike obligation leaves the app along with the rain file.

## Out of scope

Adding new soundscapes. Synthesis makes waves, wind and streams cheap to add,
and that is worth a separate conversation, but this change is about the quality
of what already exists.
