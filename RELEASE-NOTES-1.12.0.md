# Chalant 1.12.0

Three things you asked for while 1.11.0 was in Apple's queue. They were
written and tested then, but 1.11.0 was already built and could not
carry them.

## The bubble that meets a dragged file stopped shouting

Drag a screenshot toward the island and a card comes up to meet it,
away from the top edge, because macOS steals drags that linger up there
and starts minimizing your windows instead.

That card was doing too much. It carried a shadow, a large glyph, a
title, and a sentence explaining that files go to the shelf and images
go to clips: useful the first time, a lecture every time after, in the
middle of your screen while your hand was busy.

It is now wide and short instead of large and square, with no shadow
and no explanation line, and it sits closer to the island. Height is
what covers the window underneath, so the width came back and the
height did not.

## The media buttons say what they do

The skip buttons wore the double triangles that mean "scan backwards"
and "scan forwards", while what they actually do is skip a whole track.
They now wear the bar-and-triangle that means exactly that, and the
transport is drawn in outline rather than solid.

## Clear all, in clips and on the shelf

Both trays could only be emptied one row at a time. Each now has a
quiet Clear all at the bottom.

The two mean different things, and each says which when you hover it.
Clearing the shelf loses nothing: it holds bookmarks, and every file
stays where it already lives. Clearing clips deletes the screenshots
Chalant itself saved, so **pinned clips survive it**. Pinning is how you
say something should stay, and a bulk clear is exactly where that
promise would quietly break. Unpin first if a pin should go.

## Nothing else changed

Same signing, same notarization, same updates as 1.11.0.
