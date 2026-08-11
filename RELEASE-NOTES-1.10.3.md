# Chalant 1.10.3

The weather line finally gets to introduce itself.

## Weather, actually

Weather shipped in 1.10.0: a quiet line beside the date on Today, like "38° Clear". It never appeared for anyone, because the app asked macOS for location in a way macOS silently ignores, so the permission dialog never existed. The ask is fixed. The first time you run this version, macOS asks about your location once; say yes and your sky shows up beside your day, refreshed every half hour. Your position is rounded to about a kilometre before it is used, and the forecast comes from a keyless service with no account and no tracking.

While it was being fixed, the line also learned to dress for the sky: rain shows rain, snow shows snow, a storm shows a storm, instead of a sun over everything. The degrees sit in the app's monospace number style, like every other number.

The Weather switch means it now, in both directions. Off truly stops the app from reading your location at all, not just from showing the line. And flipping it back on asks macOS again if the question was never answered.

## Switches tell the truth

Turning "Calendar today" off now stops the app from reading your calendar entirely, instead of only hiding the list. Saying "join" still works, because saying it is the ask. The button that appears when Today is blank because of a switch now flips only the switch it names.

## Smaller things

- Ambience volume finally remembers where you left it after a relaunch.
- Dragging a slider on the Displays page no longer rebuilds the island on every frame of the drag; it applies once, when you let go.
- The welcome tour stopped claiming your day is off until you switch it on. It has shipped on since 1.10.2, and the tour now says what is true: macOS's own permission ask is the gate, and nothing your day contains leaves this Mac.

## Under the hood

605 tests, up from 602.
