# Chalant 1.10.2

Five fixes, all of them found by using the app on a second monitor.

## Your day, no longer hidden

The welcome tour asks for your calendar and reminders, macOS asks again, you say yes, and then Today showed nothing: both were switched off out of the box, and no screen said so. **Both now ship on.** Turning one off is still one tap, and if you had already turned one off it stays off.

And when Today is empty because something is switched off, it now says which one and turns it back on right there. A genuinely clear day still says nothing at all.

## A Pill stays a pill

On a display with no notch, the island is a free-floating bar because you chose Pill in Settings. A build in between quietly squared its corners; it does not any more. A setting has to mean what it says.

## Each display says what makes it different

The Displays list now tells you which screen has a notch and which does not, since that one fact is what decides how its island behaves. The Size card no longer appears on a pill display, where it only ever held a sentence explaining it had no controls.

## Lighter on the battery

A resting island with music playing was quietly asking for 45 full layout passes a second, because of the wave beside the notch and the breathing rim. Both now tick at a sensible rate. Measured on the same Mac: **10.7% CPU down to 7.9%**, and the layout work inside it from 18% of the main thread to 3%. The wave still dances.

## Smaller things

- The sliders on the Displays page match the island's own thin line instead of the chunky system ones, and they now announce themselves properly to VoiceOver.
- The countdown beside the notch is lighter and less cramped.
- The accent rim setting is called "while resting" rather than naming the pill, which is a display style now.

## Under the hood

602 tests, up from 600.
