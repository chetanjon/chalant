# Chalant 1.12.3

The calendar has not worked since 1.10.0, and neither of the two
releases that went after it could have fixed it. This one does.

## Your calendar works again

Open the day pane and it shows today's events. If you have never been
asked for calendar access, macOS will ask you now, properly, for the
first time since late July.

Contacts too, quietly: saying "text amma on my way" can find a number
again.

## Why the last two releases did not fix it

1.12.1 and 1.12.2 both shipped calendar permission fixes. Both found
real bugs. Neither could have worked, because the app was asking a
question the system had already decided not to answer.

Chalant runs under the hardened runtime, which closes every door by
name and opens only the ones an app declares. That went in on 24 July
with three doors open: Apple Events, the microphone, and location.
Calendar was not one of them, and neither was Contacts.

Under the hardened runtime a missing declaration is not a soft
failure. macOS refuses before you are ever involved: no prompt, no
recorded decision, nothing for System Settings to show you. So the
switch you were looking for either was not there or did nothing when
you moved it, and the app's own "Calendar access is off" card was
correct the entire time. It was reporting a refusal, not a choice you
had made.

Both doors are now declared, which is a one-line change that no amount
of work inside the app could have substituted for.

Reminders never needed a declaration and worked throughout. That is
what made this look like a calendar bug rather than an entitlement
one: the pane could show your reminders and none of your events, which
is exactly what a broken calendar would look like.

## The weather says what the sky is doing

A mainly clear afternoon read as "Partly cloudy" while the weather
station a few miles away said Mostly Clear. Chalant was collapsing two
different skies into one word. Mainly clear now says so, and wears a
sun rather than a sun behind a cloud.

The temperature was never wrong.

## Also

The release script no longer stalls in silence when macOS puts a
keychain prompt behind another window. It says what is waiting and how
to answer it, then carries on.
