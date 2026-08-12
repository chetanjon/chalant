# Releasing Chalant

```
scripts/release 1.11.0 --notes-file RELEASE-NOTES-1.11.0.md
```

That is the release. Everything below explains what it does and what
has to be true first.

## What has to be true, once, ever

Two secrets live in the login Keychain and never anywhere else. Both
are already set up on the founder's machine.

**The Sparkle key.** Installs verify an EdDSA signature made with it.

```
brew install sparkle
generate_keys
```

The public half goes in `project.yml` under `SUPublicEDKey` and ships
inside the app. The private half never leaves the Keychain. Re-running
`generate_keys` invalidates every copy of Chalant already installed,
because their built-in public key stops matching. Do not.

**The notary credentials.** Notarization talks to Apple as you.

```
xcrun notarytool store-credentials "chalant-notary" \
  --apple-id <apple id> --team-id <team id> --password <app-specific>
```

The app-specific password comes from appleid.apple.com, under Sign-In
and Security. It is not the Apple ID password.

## What the script does

Sixteen stages. It stops at the first one that fails.

1. **Preflight.** Clean tree, on `main`, tag free, tools present,
   `sign_update` located, a Developer ID identity in the Keychain, the
   notary profile resolving, `packaging/ExportOptions.plist` agreeing
   with `project.yml` about the team, every `DEVELOPMENT_TEAM` in
   `project.yml` agreeing with itself, and no stale `/Volumes/Chalant`
   mounted. `--dry-run` stops here.
2. **Bump** both version keys in `project.yml` and regenerate. Both,
   always: Sparkle compares `CFBundleVersion` and users read
   `CFBundleShortVersionString`, and `xcodegen` rewrites Info.plist
   from these two, so a version set in the plist alone disappears.
   The script owns this. Do not pre-bump `project.yml` by hand or the
   release lands a build number past the one intended.
3. **Tests.** `--skip-tests` exists for a re-run after a notarization
   failure, not for a hurry. The full log lands in `build/test.log`.
4. **Archive** Release and **export** through
   `packaging/ExportOptions.plist`, which asks for `developer-id`.
5. **Verify the signature.** Developer ID authority, hardened runtime
   flag. Five minutes in a notary queue is a slow way to learn the
   identity was wrong.
6. **Zip.**
7. **Notarize the app.** Waits on Apple. On rejection it fetches and
   prints the log, which names the offending binary.
8. **Staple the app**, then rebuild the zip, because the zip made in
   stage 6 holds an unstapled copy.
9. **Build the disk image** from the stapled app.
10. **Sign, notarize and staple the disk image.** Its own pass: a
    stapled app inside an unsigned image still gets the image blocked.
11. **`sign_update`** for the EdDSA signature and byte length.
12. **Write the appcast**, inserting the new item at the top and
    refusing to insert a version that is already there.
13. **Commit, tag, push** to `main`.
14. **Publish** the GitHub release with four assets: the versioned and
    stable disk images, and the versioned and stable zips.
15. **Kick the Pages build.** Pages does not always rebuild on a push,
    and until it does, no user's update check can see the new appcast.
16. **Ask Gatekeeper.** `spctl` must say `accepted` and
    `source=Notarized Developer ID` for both the app and the image, and
    both tickets must validate. Anything less and the script reports
    failure regardless of how well stages 1 through 15 went.

Stage 16 is the reason the script exists. A release that claims success
without Gatekeeper having agreed is the failure this whole thing was
built to end.

## Which artifact is for whom

- `Chalant.dmg` and `Chalant-<version>.dmg`: people arriving from the
  site and from Homebrew. Never referenced by the appcast. The stable
  name exists because the site links `releases/latest/download/` and
  cannot know the version.
- `Chalant-<version>.zip`: what the appcast enclosure points at, and
  therefore what Sparkle downloads.
- `Chalant.zip`: kept for anything still linking to a stable zip.

## Why the appcast has to reach `main`

GitHub Pages serves `main`'s `/docs` folder at
`chetanjon.github.io/chalant/`, and `SUFeedURL` points there. An
appcast committed on a feature branch is invisible to every user.
Stage 13 pushes to `main` for exactly this reason.

## What each half of updating is for

- Sparkle's own scheduled check is off (`SUEnableAutomaticChecks:
  false`). It never nags on its own.
- `UpdateChecker` (in-app, once a day) is what notices a release exists
  and shows the version in the dashboard.
- Clicking Install in the dashboard's General section hands the ask to
  Sparkle, which downloads, verifies against `SUPublicEDKey`, installs
  in place, and relaunches.

## Changing the signing identity

Sparkle allows it, as long as the EdDSA key does not change at the same
time. `SUUpdateValidator` accepts an update when either the EdDSA
signature verifies against the OLD app's public key or the code signing
identity matches, so a Developer ID change rides in on the unchanged
EdDSA key. Rotating both at once strands every installed copy.

macOS is less forgiving. TCC ties every permission grant to the
certificate the app carried when the grant was made, so an identity
change silently drops all of them and every user re-grants once. Say so
in the release notes. This is what happened at 1.11.0.

## Doing it by hand

If the script is not the answer, the stages above are ordinary commands
and can be run one at a time. Four traps worth carrying over:

- `sign_update` is not on `PATH`. It lives at
  `~/Library/Developer/Xcode/DerivedData/Chalant-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`,
  and there is a second copy one directory down under
  `old_dsa_scripts/` that signs with the legacy DSA algorithm and
  produces a signature Sparkle rejects.
- Nothing is notarized until `xcrun stapler validate` says so. A build
  Apple accepted but that was never stapled still works online and
  fails on a machine with no network.
- Zip after stapling, not before. The ticket goes into the bundle, so
  an archive made first carries an app without one.
- Finder styles a disk image from whatever it has cached for that mount
  path. A `/Volumes/Chalant` left over from an earlier build gets its
  icon positions applied to the next one, and the styling silently does
  nothing. `scripts/make-dmg` refuses rather than let that ship.
