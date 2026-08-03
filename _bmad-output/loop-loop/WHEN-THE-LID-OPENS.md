# What to check when the lid opens

Everything below is built, tested and pushed, and **has never been looked
at**. This Mac spent the whole build in clamshell: three externals, lid shut,
no cutout anywhere in `NSScreen.screens`. Rules were written as pure statics
and tested without a screen, which proves the arithmetic and proves nothing
about how it looks.

Open the lid, run `./scripts/dev`, and go down this list. Anything that reads
wrong is a five-minute fix; the expensive thing would be assuming it is right.

## On the MacBook's own screen

1. **The quiet island is invisible.** With nothing playing and no agent
   running, the collapsed island should be indistinguishable from the bare
   cutout. The check that settles it: quit Chalant and compare. If you can
   tell the two apart, A2 is not done.
2. **No arc along the bottom.** The old shape bowed slightly and flared at
   the corners. Quiet, it should be a clean rectangle with turned lower
   corners and nothing protruding past the housing.
3. **The corner radius is a guess.** 13pt, explicitly uncalibrated: Apple
   publishes no number and no API reports one. Compare it against the real
   cutout's corners. If it reads wrong, say tighter or rounder and it moves.
4. **Growth still emerges.** Start music or an agent. The wings should come
   out from behind the housing with the meniscus, not pop. Hover alone now
   overhangs about 3pt where it used to be 12, so the hover swell is
   deliberately subtler than before. Check it still reads as a response.
5. **Content clears the housing.** Open the island. Nothing should sit under
   the cutout.
6. **Match the notch.** Settings, Displays, the built-in. The toggle should
   be on and the note should say Chalant measures it. Turn it off: Width and
   Height should appear already holding the measured numbers, not 196x38.

## On an external display set to Notch

7. **An emulated notch still reserves its own top.** This is the one thing I
   changed after review rather than shipping as written. Set an external to
   Notch style and open the island: content must clear the drawn notch, not
   ride up under it. The rewritten rule read the hardware cutout alone, which
   would have given an emulated notch 8pt where it had always used the drawn
   height.
8. **Its meniscus is unchanged.** An emulated notch keeps the full eave. The
   real-hardware path now shrinks its eave dynamically, so these two diverge
   more than they used to; the emulated one should look exactly as it always
   has.

## Everything else that shipped unseen

9. **Sessions tab** - rows should not swap places while you watch, and the
   list should appear immediately rather than after a beat.
10. **Clipboard** - history survives a relaunch now, pages at twenty, and
    search reaches all of it rather than a page.
11. **The Arrangement drag** - one drag settles it. The row should reorder
    and the window should stay put. If the row does not move, that is the
    remaining half; the window jumping is the part that is fixed.
12. **A message you send** - the card should stay until dismissed, saying a
    hook collected it and when, and saying plainly that nothing past that is
    observable.
13. **Send a test notification** - Settings, Sessions. It fires the real
    path and clears itself after six seconds.
14. **Calendar** - grant access in System Settings and switch back to
    Chalant. The day should fill in without a relaunch.

## Still open, and why

- **The logo.** Three directions sent, parked at your call.
- **NotchBox parity** - snippets, web view, translate. Not started.
- **Drag inside the island.** The dashboard's drag now has a working
  mechanism to copy, and you have already chosen one shared arrangement
  across displays.
