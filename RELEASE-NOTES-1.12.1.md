# Chalant 1.12.1

One fix.

## Turning on calendar access now works while the island is open

The day pane could tell you calendar access was off, offer you an Open
Settings button, and then refuse to notice when you did exactly what it
asked. Granting access left the message standing until you quit Chalant
and opened it again.

Chalant has no Dock icon, so the moment it was waiting for, becoming the
active app again, is a moment that never arrives for most people. It now
watches for the change itself while the message is on screen, and the
row clears a second or two after you flip the switch.

Reminders had the same problem and is fixed by the same change.
