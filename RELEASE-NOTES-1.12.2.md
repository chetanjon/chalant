# Chalant 1.12.2

The calendar and reminders permission fix that 1.12.1 claimed and did
not deliver.

## Turning access on now works, and turning it off is noticed

Grant Chalant access to your calendar in System Settings and the day
pane picks it up within a second or two, with the island still open and
without relaunching anything. Reminders too.

The reverse matters more, and 1.12.1 made it worse rather than better.
Revoke access and Chalant used to carry on as though nothing had
happened, showing an empty day. That looks exactly like a day with
nothing in it, which is a wrong answer wearing the face of a right one.
It now says access is off, because that is what is true.

## Why it took three tries

macOS hands an app its permission status once, at launch, and that
answer never changes while the app runs. Not when you grant access, not
when you take it away. Everything here was built on reading it, so the
app was confidently wrong in both directions and a relaunch was the only
cure. It now asks the system rather than consulting an answer it was
given hours ago.

## Nothing else changed

Same signing, same notarization, same updates as 1.12.1.
