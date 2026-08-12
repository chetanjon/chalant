# Chalant 1.11.0

Chalant is signed with a Developer ID certificate and notarized by
Apple. It opens the way any Mac app opens.

Until today it was signed with a development certificate, which is a
certificate for running an app on the machine that built it. Gatekeeper
rejected it on every other Mac, which is why installing meant
unzipping, dragging, clicking past a warning with no Open button, and
then going to System Settings, Privacy and Security, and scrolling to
the bottom for Open Anyway. The Homebrew route needed
`--no-quarantine`, which asked you to disable a macOS protection on
this project's word.

None of that is true anymore. Download the disk image, drag Chalant to
Applications, open it. Homebrew is now just
`brew install --cask chetanjon/chalant/chalant`.

## Your permissions should survive

macOS ties a permission to the identity of the app that asked for it.
The certificate changed here, so this was the one thing worth worrying
about, and it turned out fine: the stored rule pins the developer team
rather than the individual certificate, and the team did not change.
Checked after installing, Location and Calendars both carried over
untouched.

If some feature is quiet after updating, the two macOS never re-asks
for on its own are the ones to check. Open System Settings, Privacy and
Security, and look under Accessibility (window snapping) and Screen
Recording (reading the front window). Everything else asks again by
itself the first time you use it.

Nothing else is lost either way. Your settings, your saved things and
your streaks are untouched.

## Updating from 1.10.5 works normally

The island will offer it and one click installs it in place, as usual.
Changing the signing identity does not break that, because updates are
verified with the project's own EdDSA key and that key has not changed.

## Nothing else changed

No feature moved. This release is the certificate and the packaging.
