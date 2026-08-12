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

## macOS will ask for your permissions again, once

This is the one cost, and it lands on everyone including me.

macOS ties every permission you grant to the certificate the app was
signed with at the moment you granted it. The certificate changed, so
the grants do not carry over. Chalant will ask again for the ones it
needs: Accessibility, Screen Recording, Microphone, Contacts,
Calendars, Reminders and Location. Each feature asks when you first use
it, the same way it asked the first time.

It happens once, on this update only. Nothing is lost besides the
grants themselves. Your settings, your saved things and your streaks
are untouched.

If a feature seems dead rather than asking, it is one of the two macOS
does not re-prompt for. Open System Settings, Privacy and Security, and
look under Accessibility (for window snapping) and Screen Recording
(for reading the front window).

## Updating from 1.10.5 works normally

The island will offer it and one click installs it in place, as usual.
Changing the signing identity does not break that, because updates are
verified with the project's own EdDSA key and that key has not changed.

## Nothing else changed

No feature moved. This release is the certificate and the packaging.
