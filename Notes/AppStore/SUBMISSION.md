# Submitting Notes to the App Store

From a clean `main` to "Waiting for Review". Do it top to bottom; each step
assumes the one before. `LISTING.md` beside this file has every piece of
text the forms ask for.

## Before you start

- A paid Apple Developer Program membership on the same team as Chalant
  (`WV59PZX4A3`). The free tier cannot upload to App Store Connect.
- Xcode 15 or newer, signed into that account (Xcode → Settings → Accounts).
- `xcodegen` (`brew install xcodegen`).
- The privacy and support pages live. They ship with the Pages site from
  `docs/notes/`; open https://chetanjon.github.io/chalant/notes/privacy.html
  in a browser and confirm it loads before you fill in the form.

## 1. Pick the store name

"Notes" is taken. Decide the store name now (see `LISTING.md`), because the
next step needs it and it is awkward to change later.

## 2. Create the app record

1. https://appstoreconnect.apple.com → My Apps → **+** → New App.
2. Platform: iOS. Name: the store name. Primary language: English (U.S.).
3. Bundle ID: `com.cj.notes`. If it is not in the list, it has not been
   registered yet: run the app on a real iPhone once from Xcode with
   automatic signing, which registers it, then reload the page.
4. SKU: `notes-ios`. User access: Full Access.
5. Create.

## 3. Register the CloudKit container for production

CloudKit has a development and a production environment. Xcode develops
against development; App Store builds use production, which starts empty.
The schema has to be pushed across once or sync silently does nothing for
store users.

1. https://icloud.developer.apple.com → CloudKit Console → pick
   `iCloud.com.cj.notes`.
2. Run the app once on a device from Xcode and create a note, so the
   `CD_Note` record type exists in Development.
3. In the console: Schema → **Deploy Schema Changes** → Deploy to Production.

Repeat this whenever the `Note` model gains a field.

## 4. Build the archive

```bash
git checkout main && git pull
cd Notes
xcodegen generate
open Notes.xcodeproj
```

In Xcode:

1. Scheme `Notes`, destination **Any iOS Device (arm64)**.
2. Product → **Archive**. Release configuration, automatic signing; Xcode
   swaps the push entitlement to production on its own.
3. The Organizer opens on the new archive. Validate App first (catches a
   missing icon or a bad entitlement in a minute rather than after upload).
4. **Distribute App** → App Store Connect → Upload → accept the defaults
   (upload symbols, manage version and build number: off, since
   `project.yml` owns those) → Upload.

Processing takes ten to thirty minutes. App Store Connect emails when the
build is ready.

## 5. Fill in the listing

In App Store Connect → the app → the **1.0 Prepare for Submission** page.
Work down the page with `LISTING.md` open:

1. Screenshots: drag the 6.9-inch set in.
2. Promotional text, description, keywords, support URL, marketing URL.
3. Build: **+** and pick the build you uploaded.
4. App icon: taken from the build. Nothing to upload.
5. Version 1.0.0, copyright.
6. App Review information: your contact details, the reviewer notes from
   `LISTING.md`, sign-in required: no.
7. Version release: **Manually release this version**. That way approval
   does not put it on the store while you are asleep; you press Release
   when ready. (Automatic is fine too if you would rather not wait.)

Left sidebar, still to do once each:

8. **App Information**: category Productivity, secondary Utilities, content
   rights: no third-party content. Privacy Policy URL.
9. **Pricing and Availability**: Free, all territories.
10. **App Privacy**: Get Started → Data Not Collected → Publish.
11. **Age Rating**: Edit → none of the above for everything → 4+.

## 6. Submit

Back on the version page: **Add for Review** → **Submit to App Review**.
Status goes to Waiting for Review, then In Review (usually within a day or
two for a first submission), then either Ready for Distribution or
Rejected with a message.

If it is rejected, the message names a guideline. Paste it here and the
fix is usually small. The ones a first submission of this app could hit:

- **2.1 Performance, crash on launch.** They test on a device not signed
  into iCloud. The app handles that (local store fallback); if it crashes
  anyway, the crash log is attached to the rejection.
- **2.3 Accurate metadata.** A screenshot showing something the build does
  not do. Keep the screenshots to real screens.
- **4.2 Minimum functionality.** Rare for an app with sync, widgets, and
  checklists, but the reviewer notes exist to head this off: they point
  at the Lock Screen feature straight away.
- **5.1.1 Privacy policy.** The URL must load and must mention iCloud. The
  page in `docs/notes/` does both.

## 7. Release

Ready for Distribution → **Release This Version**. It is live in a few
hours. Share the App Store link, or `https://apps.apple.com/app/id<the id>`
from the App Information page.

## Every release after this one

1. Bump `MARKETING_VERSION` (what people see) and `CURRENT_PROJECT_VERSION`
   (must go up every upload) in `Notes/project.yml`. Commit on a branch, PR,
   merge.
2. `xcodegen generate`, Archive, Upload (steps 4.1 to 4.4).
3. App Store Connect → **+** next to iOS App → new version → What's New →
   pick the build → Submit.
4. If the `Note` model changed, deploy the CloudKit schema to production
   (step 3) before you submit, not after.

## Not required, worth doing

- **TestFlight first.** After the upload in step 4, the same build appears
  under TestFlight. Add yourself and a few friends as internal testers and
  live with it for a few days before step 6. No review is needed for
  internal testers.
- **App Store Connect app** on your phone, for status and review messages.
