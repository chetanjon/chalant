# Notarized, and easy to get

Chalant 1.11.0. Distribution, not product: no feature changes, no new
surfaces in the app. What changes is that macOS stops treating Chalant
as something suspicious, and the website stops apologizing for it.

## The problem, measured

The shipped 1.10.5 is signed with a development certificate:

```
$ spctl -a -vvv -t install ~/Downloads/installations/Chalant.app
rejected
origin=Apple Development: j.chetan9009@gmail.com (7JK5N68ZSM)
```

`rejected` is the whole problem, and no amount of packaging fixes it.
A development certificate exists to run an app on the machine that
built it. It can never satisfy Gatekeeper on somebody else's Mac.

Everything that follows from that rejection is currently absorbed by
the user and papered over with copy:

- The landing page's fine print is a three-step ceremony:
  `unzip · drag chalant to applications · first open: system settings,
  privacy and security, open anyway`.
- The install command carries `--no-quarantine`, which asks a stranger
  to disable a macOS protection on the project's word.
- The Homebrew cask ships a caveats block explaining how to click past
  a warning, including the instruction "click Done, not Move to Trash".
- README says it in four places, ending with "a notarized build if
  enrollment ever earns its $99".

## What it takes

Notarization requires a **Developer ID Application** certificate, which
exists only inside a paid Apple Developer Program membership. There is
no free tier and no substitute authority. The founder has decided to
enroll.

Everything else notarization demands is already true of this app, which
is the fortunate part:

- `ENABLE_HARDENED_RUNTIME: YES` is already set in `project.yml`.
- `Chalant.entitlements` already holds exactly three entitlements, each
  with a written justification, and deliberately omits
  `disable-library-validation`.
- `get-task-allow` never ships in a Release archive.
- Every embedded binary that the notary service inspects is already
  present and already signed as part of the build: Sparkle's
  `Autoupdate`, `Updater.app`, `Downloader.xpc` and `Installer.xpc`,
  plus `MediaRemoteAdapter.framework` and four scripts in Resources.

So this is a certificate swap and a pipeline, not a remediation.

## Two consequences, both verified against source

### Existing users update normally

Sparkle accepts the identity change. `SUUpdateValidator.m` documents
the rule at `validateUpdateForHost:`:

```
 * If the update is a bundle, then it must meet any one of:
 *  * old and new Ed(DSA) public keys are the same and valid
 *    (it allows change of Code Signing identity), or
 *  * old and new Code Signing identity are the same and valid
```

and enforces it as:

```objc
// Either DSA must be valid, or Apple Code Signing must be valid.
// We allow failure of one of them, because this allows key rotation
// without breaking chain of trust.
if (passedDSACheck || passedCodeSigning) { return YES; }
```

`SUPublicEDKey` does not change and `sign_update` uses the same
Keychain private key, so `passedDSACheck` is true and the update
installs. Nobody on 1.10.5 has to re-download anything.

The one adjacent check: when the EdDSA check passes and the new bundle
is code signed, Sparkle also requires the new signature to be valid on
its own terms (`codeSignatureIsValidAtBundleURL:`). A notarized
Developer ID build satisfies that by construction.

### Permissions reset once, for everyone

TCC keys every grant to the code signing requirement captured at grant
time. Moving from `Apple Development (WV59PZX4A3)` to
`Developer ID Application (new team)` invalidates all of them. Every
user, the founder included, re-grants Accessibility, Screen Recording,
Microphone, Contacts, Calendars, Reminders and Location one time.

This is unavoidable and it is precisely what the existing comment in
`project.yml` was protecting against:

```yaml
# Stable dev-cert signing: ad-hoc re-signing made every rebuild
# look like a new app, resetting Keychain and TCC grants.
```

That comment stops being true and gets rewritten.

**Decision: the 1.11.0 release notes carry this, and nothing else
does.** No one-time banner, no apology UI. A control that exists to
explain a single release is a control that cannot act, and it would
still be sitting there in 1.14. The three features that need
permissions (`ScreenReader`, `WindowSnapper`, `EventKitService`) each
already detect denial and ask on their own. A proper permissions pane
is a real gap and a real idea, but it is its own project and it is out
of scope here.

## The design

### 1. Signing splits by configuration

`project.yml` today applies one identity to everything. It gains a
`configs` block:

```yaml
settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: com.cj.chalant
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: <paid team id>
    ...
  configs:
    Debug:
      CODE_SIGN_IDENTITY: "Apple Development"
    Release:
      CODE_SIGN_IDENTITY: "Developer ID Application"
```

Daily development keeps the fast, local identity. Only archives are
Developer ID. The `ChalantTests` target keeps `Apple Development`
unchanged.

`DEVELOPMENT_TEAM` becomes the paid team's ID, read off the new
certificate rather than assumed. Individual enrollment issues a team
ID that is generally **not** the personal team's `WV59PZX4A3`, so this
value is discovered, never guessed.

### 2. ExportOptions.plist exists for the first time

`RELEASING.md` currently instructs `-exportArchive` against an
`ExportOptions.plist` that is not in the repo, which is why the actual
practice drifted to using the xcarchive's app directly. The file gets
written:

```xml
<key>method</key>        <string>developer-id</string>
<key>teamID</key>        <string>PAID_TEAM_ID</string>
<key>signingStyle</key>  <string>automatic</string>
<key>destination</key>   <string>export</string>
```

Chalant's entitlements are hardened-runtime entitlements rather than
capability entitlements, so no provisioning profile is required and
automatic signing resolves the whole thing.

### 3. Notary credentials, once, in the Keychain

```
xcrun notarytool store-credentials "chalant-notary" \
  --apple-id <apple id> --team-id <paid team id> \
  --password <app-specific password>
```

Stored in the login Keychain beside the Sparkle EdDSA key. Nothing
secret enters the repo, an environment variable, or a build log. This
matches the existing rule for the Sparkle key exactly.

### 4. `scripts/release` replaces the ritual

One command:

```
scripts/release 1.11.0 --notes-file RELEASE-NOTES-1.11.0.md
```

Stages, in order, each failing loudly and stopping:

1. **Preflight.** Clean git tree. On `main`. `xcodegen`, `gh`,
   `hdiutil`, `tiffutil` present. `sign_update` located (it lives in
   DerivedData SourcePackages, not on PATH). A `Developer ID
   Application` identity exists in the Keychain. The `chalant-notary`
   profile resolves. Version not already tagged.
2. **Bump.** `CFBundleShortVersionString` and `CFBundleVersion` in
   `project.yml`, then `xcodegen generate`. Both keys, because
   xcodegen regenerates Info.plist and Sparkle compares the integer.
3. **Test.** Full suite. `--skip-tests` exists for re-runs after a
   failed notarization, and says so in its help.
4. **Archive** Release, then **export** through `ExportOptions.plist`.
5. **Verify signature.** `codesign --verify --deep --strict` plus an
   assertion that the authority is Developer ID and the runtime flag
   is set. Catching this here rather than at the notary saves five
   minutes per mistake.
6. **Zip** with `ditto -c -k --sequesterRsrc --keepParent`.
7. **Notarize the zip**, `--wait`. On rejection, fetch and print
   Apple's log, then stop.
8. **Staple the app.** The ticket is embedded, so first launch works
   with no network.
9. **Build the DMG** from the stapled app (below).
10. **Notarize and staple the DMG.** A second submission is required:
    a stapled app inside an un-notarized disk image still gets the
    disk image blocked on arrival.
11. **`sign_update`** on the versioned zip for the EdDSA signature and
    byte length.
12. **Rewrite `docs/appcast.xml`** with version, short version,
    pubDate, enclosure URL, length and signature.
13. **Commit, tag, push** to `main`. The appcast is invisible to users
    anywhere else.
14. **`gh release create`** with the DMG and both zips.
15. **Kick the Pages build** (`gh api -X POST .../pages/builds`).
    Required after every release and currently remembered by hand.
16. **Assert.** `spctl -a -t install` on the app and
    `spctl -a -t open --context context:primary-signature` on the DMG.
    Both must say accepted, with `source=Notarized Developer ID`, or
    the script reports failure regardless of everything that passed.

Stage 16 is the point of the script. A release that reports success
without Gatekeeper having agreed is the failure mode this whole
project exists to end.

### 5. The DMG

Built from the stapled app, not the raw one, so the disk image carries
an app that is already notarized independently.

```
staging/  Chalant.app  +  symlink -> /Applications
hdiutil create -srcfolder staging -format UDRW -volname Chalant
mount, apply window styling via AppleScript, unmount
hdiutil convert -format UDZO
```

Window: 660x420, icons at 25% and 75% width (x=165 and x=495) on the
y=200 line, 128pt icon size, toolbar and status bar off. A quarter and
three quarters rather than something tighter: at 128pt, icons placed at
40% and 60% would sit 132pt apart and nearly touch, leaving the arrow
nowhere to go. At 165 and 495 their inner edges are 202pt apart.

Background: a `tiffutil -cathidpicheck` two-rep image (660x420 and
1320x840) so it is sharp on Retina. Drawn in the landing page's own
palette, which is the app's:

- ground `#000000`
- one thin arrow between the two icons in `#5a5a5a` (`--ghost`)
- nothing else. No wordmark, no instruction text, no border.

Flat black, air rather than lines, one symbol carrying one meaning.
The two icons and the arrow between them say the entire thing.

Sparkle continues to consume the zip. The DMG is for people arriving
from the website, and is never referenced by the appcast.

### 6. The copy stops apologizing

| File | Today | After |
|---|---|---|
| `docs/index.html` button + JS href | `Chalant.zip` | `Chalant.dmg` |
| `docs/index.html` fine print | `unzip · drag chalant to applications · first open: system settings, privacy and security, open anyway` | `open · drag to applications` |
| `docs/index.html` "First open" section | Explains the ceremony, `--no-quarantine`, and "Chalant is unsigned because it is free and independent" | Section removed. Its privacy content (public source, Apple dictation, what reaches the internet, the Chat tab disclaimer) survives intact, moved up. |
| `README.md` download block | `--no-quarantine`, "macOS asks once", "Click Done, not Move to Trash" | Download, drag, open |
| `README.md` line 127 | "Unsigned; the first open needs one Open Anyway." | Removed |
| `README.md` line 131 | "since you are running an unsigned app that can touch a lot" | Rewritten without the disclaimer |
| `README.md` line 143 | "a notarized build if enrollment ever earns its $99" | Replaced with the fact |
| `homebrew-chalant` cask | `--no-quarantine` in the command, plus a caveats block | Plain `brew install --cask chetanjon/chalant/chalant`, caveats deleted, `url` points at the DMG |
| `docs/RELEASING.md` | A parenthetical "(Notarize per Apple's usual...)" | Rewritten around `scripts/release`, with the manual path kept for when the script is not the answer |

The `--no-quarantine` flag disappearing from the install command is the
most visible change in the project. It currently asks a stranger to
disable a macOS protection on the project's word.

## Sequencing

Only one item is blocked on Apple.

**Founder, once.** Enroll at `developer.apple.com/programs/enroll` as
an **Individual**, not an Organization (Organization requires a D-U-N-S
number and takes weeks). $99/year, same Apple ID already in use.
Approval is usually same day, sometimes 24 to 48 hours. Then create an
app-specific password at `appleid.apple.com` under Sign-In and
Security. Hand over the team ID and that password.

**Unblocked, buildable now.** The DMG builder and its background art,
`scripts/release` end to end, `ExportOptions.plist`, and every word of
copy in the table above. All of it exercised against the current
dev-signed build, with the notarization stages dry-run.

**After enrollment.** Flip the two identity lines in `project.yml`,
store the notary credentials, run `scripts/release 1.11.0` for real,
confirm `spctl` says accepted, install locally, re-grant permissions
once and confirm the app recovers cleanly, publish.

## Ships as

1.11.0, `CFBundleVersion` 148. A minor bump rather than a patch: no
feature moved, but "signed by Apple" is the most user-visible thing
this project has changed in months.

## Out of scope

- A permissions pane. Real gap, real idea, its own project.
- Any in-app UI about the permission reset. Release notes carry it.
- Changing the Sparkle EdDSA key. It stays, and it is what lets
  existing users cross the identity change at all.
- App Store distribution. Different certificate, different sandbox,
  and this app holds Accessibility and Screen Recording.

## Verification

The release is complete when, on a Mac that has never seen Chalant:

1. `curl -L` the DMG from the releases URL, open it in Finder, drag,
   double-click, and the app opens after **one click on Open**.

   Precision matters here, because the goal is not zero dialogs. A
   notarized app that arrived through a browser still shows macOS's
   ordinary consent sheet: *"Chalant is an app downloaded from the
   Internet. Are you sure you want to open it?"*, with an Open button
   that works. That sheet is what every Mac app gets and nobody
   thinks twice about.

   What ends is the other one: *"Apple could not verify Chalant is
   free of malware"*, which has no Open button at all and sends the
   user to System Settings, Privacy and Security, scroll to the
   bottom, Open Anyway. Since macOS 15 not even right-click-Open
   bypasses it. That is the dialog this project removes.
2. `spctl -a -vvv -t install /Applications/Chalant.app` prints
   `accepted` and `source=Notarized Developer ID`.
3. `xcrun stapler validate /Applications/Chalant.app` prints
   `The validate action worked!`.
4. A machine still on 1.10.5 sees the update, clicks Install, and
   lands on 1.11.0 through Sparkle without re-downloading.
