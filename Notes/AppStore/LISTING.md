# App Store listing

Everything App Store Connect asks for, in the order its form asks. Paste
from here. Character limits are Apple's; every field below is inside them.

## App name (30 characters)

"Notes" alone is taken on the App Store, so the store name has to be
something else. The name on the Home Screen stays "Notes" regardless: that
is `CFBundleDisplayName` in `project.yml`, and Apple allows the two to differ.

Recommended: **Chalant Notes**

Fallbacks if that is taken when you type it: **Noir Notes**, **Plain Notes**.

## Subtitle (30 characters)

Recommended: **Pinned to your Lock Screen**

Fallback: **Minimal notes, Lock Screen**

## Category

Primary: Productivity. Secondary: Utilities.

## Promotional text (170 characters, editable without a new build)

The notes app that stays out of the way. Pure black, no clutter, and the one note you must not forget sits on your Lock Screen.

## Description (4000 characters)

A notes app with nothing in the way.

Notes is black and white and dark only. Open it and write. The first line is the title. Everything saves as you type; there is no save button and nothing to set up.

PIN ONE NOTE TO YOUR LOCK SCREEN
Long-press a note and pin it. It shows on your Lock Screen every time you pick up the phone, so the thing you must not forget is the first thing you see. Tap it and the note opens. Pin a different note and it takes its place.

CHECKLISTS INSIDE YOUR NOTES
Turn any line into a checklist item with one tap. Tick items off in the note, and the list shows how far along you are: "2/5 done · milk, eggs".

SEARCH EVERYTHING
Search matches titles and bodies as you type, with every match highlighted.

SYNCS THROUGH YOUR ICLOUD
Your notes appear on all your iPhones, through your own iCloud. There is no account to create, no server, and no sign-in.

NOTHING COLLECTED
No analytics, no tracking, no ads, no third-party code. The developer cannot read your notes. See the privacy policy: it fits on one screen.

WHAT IT DOES NOT DO
No folders, tags, colours, fonts, images, or sharing. No light mode. It is for the notes you write in a hurry and need to see again.

Requires iOS 17 or later.

## Keywords (100 characters, comma separated, no spaces)

notes,lock screen,widget,checklist,minimal,dark,black,quick notes,notepad,todo,memo,icloud

## URLs

| Field | Value |
|---|---|
| Support URL | https://chetanjon.github.io/chalant/notes/ |
| Marketing URL (optional) | https://chetanjon.github.io/chalant/notes/ |
| Privacy Policy URL | https://chetanjon.github.io/chalant/notes/privacy.html |

Both pages are in `docs/notes/` in this repo and go live with the Pages site.

## Version information

| Field | Value |
|---|---|
| Version | 1.0.0 (must match `MARKETING_VERSION` in `project.yml`) |
| Copyright | 2026 Chetan Jonnalagadda |
| What's New (first release) | First release. |

## Age rating

Answer "None" to every question in the questionnaire. Result: 4+.

## App Privacy (the nutrition label)

Choose **Data Not Collected**.

Why that is the truthful answer: notes live on the device and in the user's
own CloudKit private database, which the developer cannot read. Apple's
definition of "collected" is data sent off the device to the developer or a
third party in a way they can access. Nothing in the app does that. There
are no analytics, no crash reporting SDKs, no ads, no identifiers.

## App Review information

| Field | Value |
|---|---|
| Sign-in required | No |
| Contact | your name, phone, and email (Apple contacts you here if the review has a question) |
| Notes for the reviewer | see below |

Notes for the reviewer, paste as is:

> Notes is a local-first notes app. No account is needed. To test the Lock
> Screen feature: create a note, long-press it in the list, choose "Pin to
> Lock Screen", then add the Notes widget to the Lock Screen (long-press
> the Lock Screen → Customize → Lock Screen → tap the area under the clock
> → Notes). iCloud sync uses the CloudKit private database and needs a
> device signed into iCloud; it is optional and the app works without it.

## Screenshots

Required: one set for the 6.9-inch iPhone display. Apple scales it to the
smaller sizes. Sizes it accepts: 1320 × 2868 or 1290 × 2796 pixels, portrait.

How to take them: in Xcode pick an iPhone 17 Pro Max (or 16 Pro Max)
simulator, run the app, set up each screen, press ⌘S in Simulator. The PNG
lands on the Desktop at the right size. No device frame is needed and none
is added; the black app on a black background is the look.

Take these five, in this order (the first two do most of the selling):

1. **The list** with four or five notes, one pinned. Titles that read like
   real life: "Walking app v1 scope", "Groceries" (a checklist, showing
   "1/4 done · eggs, milk"), "Call amma re: Sunday", "Book title ideas".
2. **The Lock Screen** with the widget showing the pinned note. Take this on
   a real phone (Lock Screen widgets do not render in the simulator's Lock
   Screen); a real-device screenshot of a 6.9-inch phone is the right size.
3. **A checklist** open in the editor, two items ticked.
4. **Search** with a query typed and matches highlighted.
5. **A plain note** open in the editor, cursor at the end, keyboard up.

Optional: a caption above each. Keep them short and in the app's voice:
"Nothing in the way." / "One note, always in sight." / "Checklists, inline."
/ "Find it fast." / "Just write."
