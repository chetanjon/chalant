# Releasing Chalant

GitHub Releases is the source of truth. Sparkle (in the app) checks
`docs/appcast.xml`, which is only live once it is on `main` — GitHub
Pages for `chetanjon.github.io/chalant/` serves `main`'s `/docs` folder
(Settings → Pages on the `chetanjon/chalant` repo). Committing the
appcast on a feature branch does nothing for users; it must land on
`main`.

## One-time: generate the signing key

Sparkle installs verify an EdDSA signature. Do this once, ever, and
never on a machine other than the founder's:

```
brew install sparkle
generate_keys
```

This writes the private key to the login Keychain and prints the
public key. Put the public key in `project.yml` under
`SUPublicEDKey` (Info.plist section) — it is not a secret, it ships
inside the app. The private key never leaves Keychain and never goes
in the repo, an env var, or a build log.

`project.yml` already carries a `SUPublicEDKey` value and has shipped
several real releases (1.2.13 through 1.3.3) against it, so this step
is almost certainly already done. Re-run it only if updates start
failing signature verification and there is reason to believe the
Keychain entry was lost (new machine, wiped Keychain) — a new key
invalidates every copy of the app already in the wild, since their
built-in public key stops matching.

## Every release

1. **Bump the version** in `project.yml`: `CFBundleShortVersionString`
   (the number users see, e.g. `1.3.4`) and `CFBundleVersion` (an
   integer, always incremented, e.g. `121`). Sparkle compares
   `CFBundleVersion`, not the short string. Run `xcodegen generate`.

2. **Archive and export a signed .app**:
   ```
   xcodebuild archive -scheme Chalant -configuration Release \
     -archivePath build/Chalant.xcarchive \
     DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Automatic
   xcodebuild -exportArchive -archivePath build/Chalant.xcarchive \
     -exportPath build/export -exportOptionsPlist ExportOptions.plist
   ```
   (Notarize per Apple's usual `notarytool submit` / `stapler staple`
   if this build is meant for Gatekeeper outside the App Store — do
   that before zipping.)

3. **Zip it twice**, same bits, two names — the appcast and the
   website's "latest" link expect different asset names:
   ```
   cd build/export
   ditto -c -k --sequesterRsrc --keepParent Chalant.app Chalant-1.3.4.zip
   cp Chalant-1.3.4.zip Chalant.zip
   ```

4. **Sign the update** (needs the Keychain key from the one-time step):
   ```
   sign_update Chalant-1.3.4.zip
   ```
   Prints an `sparkle:edSignature` value and the file's byte length.

5. **Update `docs/appcast.xml`**: replace the single `<item>` with the
   new version's title, `pubDate`, `sparkle:version` (the integer),
   `sparkle:shortVersionString`, and an `<enclosure>` whose `url`
   points at the versioned asset below, `length` is the byte count
   from step 4, and `sparkle:edSignature` is that step's output.

6. **Create the GitHub release**: tag `v1.3.4`, upload both
   `Chalant-1.3.4.zip` and `Chalant.zip` as assets.
   ```
   gh release create v1.3.4 Chalant-1.3.4.zip Chalant.zip \
     --title "1.3.4" --notes "..."
   ```
   The appcast enclosure URL is
   `https://github.com/chetanjon/chalant/releases/download/v1.3.4/Chalant-1.3.4.zip`.

7. **Merge `docs/appcast.xml` (and the version bump) to `main`.**
   Nothing above is visible to a user's Sparkle check until this
   lands there — Pages serves `main`'s `/docs`, not the branch that
   cut the release.

## What each half is for

- Sparkle's own scheduled check is off (`SUEnableAutomaticChecks:
  false`). It never nags on its own.
- `UpdateChecker` (in-app, once a day) is what notices a release
  exists and shows the version in the dashboard.
- Clicking Install in the dashboard's General section is what hands
  the ask to Sparkle, which downloads, verifies against
  `SUPublicEDKey`, installs, and relaunches.

If `SUPublicEDKey` is ever a placeholder (it is not, today) — every
install attempt fails signature verification silently to the user
except for Sparkle's own error dialog. Run the one-time step above
before shipping a release built against a placeholder key.
