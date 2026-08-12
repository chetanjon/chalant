# Chalant 1.10.5

Music stops costing anything.

## The dance moved to the render server

While a track played, the resting island's two small animations (the bars dancing beside the title, and the album-colored rim breathing at the edge) were quietly costing real CPU: every frame of theirs made the whole island re-measure itself, even after 1.10.2 slowed their tick rates. Both now play on macOS's own render server. The app describes the dance once, and the system performs it.

Same bars, same breath, same rhythm, to the pixel. Measured on the same Mac with the same music: what took six to nine percent of a core now takes one to two, which is about what the island costs in silence.

Reduce Motion still parks the bars, exactly as before.

## Under the hood

615 tests, up from 614.
