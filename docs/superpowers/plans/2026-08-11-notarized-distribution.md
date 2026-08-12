# Notarized Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Chalant 1.11.0 signed with a Developer ID certificate and notarized by Apple, delivered as a designed DMG, with every apology for being unsigned deleted from the site, the README and the Homebrew cask.

**Architecture:** Signing splits by build configuration so daily development keeps its fast local identity and only archives are Developer ID. A single `scripts/release` runs the whole ritual and refuses to report success until `spctl` agrees the result is notarized. The DMG's background art is generated from code, never hand drawn, following the rule `scripts/make-icon.py` already sets for the app icon.

**Tech Stack:** bash, XcodeGen, `xcodebuild`, `xcrun notarytool`, `xcrun stapler`, `hdiutil`, `tiffutil`, Finder AppleScript, Python 3 with PIL, Sparkle's `sign_update`, `gh`.

## Global Constraints

- **No em dashes anywhere.** Not in code comments, not in shell output, not in site copy, not in commit messages. Use a period, comma, colon or parentheses. This is a standing rule of this repo.
- **Version for this release:** `CFBundleShortVersionString: 1.11.0`, `CFBundleVersion: "148"`. Both live in `project.yml`, never in `Chalant/Info.plist`, because `xcodegen generate` rewrites Info.plist and a version set only there silently resets.
- **Team ID is discovered, never guessed.** Every file that needs it reads it from one place: `DEVELOPMENT_TEAM` in `project.yml`. Until enrollment completes that value stays `WV59PZX4A3`. Task 7 changes it in exactly one file.
- **Nothing secret enters the repo.** The Sparkle EdDSA private key and the notary credentials both live in the login Keychain. Not in a file, not in an environment variable, not in a build log.
- **`SUPublicEDKey` never changes.** It is `HS35RsdFpfDTLuf/jX4Cnv7YLzzC72iXqlyPkbYfAzE=` and it is the only reason existing users can cross the code signing identity change. Touching it invalidates every copy of Chalant in the wild.
- **Palette, for anything drawn:** ground `#000000`, ghost `#5a5a5a`, mist `#9a9a9a`, ink `#f2f2f2`. These are the landing page's CSS custom properties and they are the app's.
- **`sign_update` has an evil twin.** The correct binary is at `SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`. There is also one at `.../bin/old_dsa_scripts/sign_update` which signs with the legacy DSA algorithm and will produce a signature Sparkle rejects. Every lookup must exclude `old_dsa_scripts`.
- **Scripts follow the repo's existing shape.** Executable, no extension, `set -euo pipefail`, a comment block at the top explaining why the script exists rather than what it does. See `scripts/dev` and `scripts/chalant-hook-selftest`.

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `scripts/make-dmg-background.py` | Draws the disk image window's background from a GEOMETRY block. The only place that art exists. |
| `packaging/dmg-background.tiff` | Generated two-representation output of the above, committed so a release does not depend on PIL being installed. |
| `packaging/ExportOptions.plist` | Tells `xcodebuild -exportArchive` to produce a Developer ID build. |
| `scripts/make-dmg` | Turns a stapled `.app` into the styled disk image. Knows nothing about versions, notarization or git. |
| `scripts/make-dmg-selftest` | Proves `make-dmg` produces a mountable image with the right contents, using a stub app. |
| `scripts/release` | Orchestrates everything and asserts Gatekeeper agrees before reporting success. |
| `RELEASE-NOTES-1.11.0.md` | Release notes, including the one-time permission reset. |

**Modify:**

| Path | Change |
|---|---|
| `project.yml` | Split `CODE_SIGN_IDENTITY` into a `configs` block; bump both version keys; rewrite the stale signing comment. |
| `scripts/dev` | Stop hardcoding the team ID; read it from `project.yml`. |
| `docs/index.html` | Download button and its JS twin point at the DMG; fine print loses the ceremony; the "First open" section is rewritten. |
| `README.md` | Five places that call the app unsigned. |
| `docs/RELEASING.md` | Rewritten around `scripts/release`. |
| `chetanjon/homebrew-chalant` `Casks/chalant.rb` | Drop `--no-quarantine` and the caveats block; point at the DMG. Separate repo, edited through `gh`. |

---

### Task 1: The disk image background

**Files:**
- Create: `scripts/make-dmg-background.py`
- Create: `packaging/dmg-background.tiff` (generated, committed)
- Test: manual assertions in Step 3, plus eyeballing the PNG

**Interfaces:**
- Consumes: nothing
- Produces: `packaging/dmg-background.tiff`, a two-representation TIFF whose 1x rep is 660x420 and whose 2x rep is 1320x840. `scripts/make-dmg` reads this exact path.

The window is 660x420. Icons sit at x=165 and x=495 on the y=200 centre line at 128pt, so their inner edges are at x=229 and x=431. The arrow lives in that 202pt gap and touches neither.

- [ ] **Step 1: Write the generator**

Create `scripts/make-dmg-background.py`:

```python
#!/usr/bin/env python3
"""Draws the background of the disk image people download.

Same rule as scripts/make-icon.py: nothing here is hand drawn and the
TIFF is never edited by hand. To change the window, change a number in
GEOMETRY below and run this again.

The palette is the site's, which is the app's: a black ground, one
arrow in --ghost, and nothing else. Finder puts Chalant and the
Applications alias on top of this, and those two icons plus the arrow
between them say the whole thing. No instruction text, no wordmark, no
border.

Usage:  python3 scripts/make-dmg-background.py [outdir]

Writes background.png, background@2x.png and background.tiff into
packaging/ (or outdir). scripts/make-dmg reads the TIFF.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# Everything is measured in the window's own points and scaled from there.
GEOMETRY = {
    "width": 660,       # the Finder window scripts/make-dmg asks for
    "height": 420,
    "axis": 200,        # the centre line both icons sit on
    "reach": 34,        # half the arrow's length
    "head": 9,          # how far each leg of the chevron reaches back
    "stroke": 1.5,      # hairline, in points
}

GROUND = (0x00, 0x00, 0x00)
GHOST = (0x5A, 0x5A, 0x5A)

# PIL does not antialias a stroked line, and the chevron's legs are
# diagonal. Draw large, then come back down.
SUPERSAMPLE = 4


def render(scale: int) -> Image.Image:
    g = GEOMETRY
    s = scale * SUPERSAMPLE
    width, height = g["width"] * s, g["height"] * s

    canvas = Image.new("RGB", (width, height), GROUND)
    pen = ImageDraw.Draw(canvas)

    cx, cy = width // 2, g["axis"] * s
    reach, head = g["reach"] * s, g["head"] * s
    stroke = max(1, round(g["stroke"] * s))
    tip = cx + reach

    pen.line([(cx - reach, cy), (tip, cy)], fill=GHOST, width=stroke)
    pen.line([(tip - head, cy - head), (tip, cy)], fill=GHOST, width=stroke)
    pen.line([(tip - head, cy + head), (tip, cy)], fill=GHOST, width=stroke)

    return canvas.resize(
        (g["width"] * scale, g["height"] * scale), Image.LANCZOS
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "packaging"
    outdir.mkdir(parents=True, exist_ok=True)

    one = outdir / "background.png"
    two = outdir / "background@2x.png"
    render(1).save(one)
    render(2).save(two)

    # Finder reads one file and picks the representation the display
    # deserves. tiffutil is the only supported way to make that file.
    tiff = outdir / "dmg-background.tiff"
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(tiff)],
        check=True,
        stdout=subprocess.DEVNULL,
    )

    print(f"wrote {tiff.relative_to(root)}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

```bash
python3 scripts/make-dmg-background.py
```

Expected: `wrote packaging/dmg-background.tiff`

- [ ] **Step 3: Assert the output is what Finder needs**

```bash
sips -g pixelWidth -g pixelHeight packaging/background.png
sips -g pixelWidth -g pixelHeight packaging/background@2x.png
tiffutil -info packaging/dmg-background.tiff | grep -c "Resolution"
```

Expected: `660 x 420`, then `1320 x 840`, then a count of at least 2 (one per representation). If the count is 1, `tiffutil` collapsed the reps and Finder will render the background soft on Retina.

- [ ] **Step 4: Look at it**

```bash
open packaging/background@2x.png
```

It must be pure black with one thin grey arrow slightly above centre, pointing right, nothing else. If the arrow's diagonals look stepped, `SUPERSAMPLE` is not being applied.

- [ ] **Step 5: Keep the PNGs out of the repo**

Only the TIFF is committed. Add to `.gitignore`:

```
# Intermediate reps for the disk image background. The TIFF that
# packaging/ commits is built from these by scripts/make-dmg-background.py.
packaging/background.png
packaging/background@2x.png
```

- [ ] **Step 6: Commit**

```bash
git add scripts/make-dmg-background.py packaging/dmg-background.tiff .gitignore
git commit -m "feat(dmg): the window's background, drawn from code

Same rule the app icon has had since make-icon.py: the art is a
function of GEOMETRY, and the TIFF is never edited by hand.

Black ground, one arrow in --ghost between where the two icons land,
nothing else."
```

---

### Task 2: Build the disk image

**Files:**
- Create: `scripts/make-dmg`
- Create: `scripts/make-dmg-selftest`
- Reads: `packaging/dmg-background.tiff` from Task 1

**Interfaces:**
- Consumes: `packaging/dmg-background.tiff` (Task 1).
- Produces: `scripts/make-dmg <path/to/Chalant.app> <path/to/out.dmg>`. Exits non-zero with a message on stderr if the app or the background is missing. `scripts/release` (Task 4) calls exactly this.

**Gotcha to expect:** the Finder AppleScript needs Automation permission for whatever terminal runs it. The first run shows a "Terminal wants to control Finder" prompt. If it is denied, `osascript` fails with error -1743 and the script stops with a hint pointing at System Settings.

- [ ] **Step 1: Write the failing test**

Create `scripts/make-dmg-selftest`:

```bash
#!/bin/bash
# Proves scripts/make-dmg produces a mountable disk image carrying the
# app, an Applications alias and the background, without needing a real
# Chalant build (an archive takes minutes; this takes seconds). The app
# it packages is a stub whose only job is to be a bundle.
#
# Run directly: scripts/make-dmg-selftest
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKE_DMG="$HERE/make-dmg"
WORKDIR="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

STUB="$WORKDIR/Chalant.app"
mkdir -p "$STUB/Contents/MacOS"
cat > "$STUB/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Chalant</string>
  <key>CFBundleIdentifier</key><string>com.cj.chalant.stub</string>
  <key>CFBundleName</key><string>Chalant</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
printf '#!/bin/bash\nexit 0\n' > "$STUB/Contents/MacOS/Chalant"
chmod +x "$STUB/Contents/MacOS/Chalant"

OUT="$WORKDIR/Chalant-test.dmg"

FAILURES=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok - $label"
  else
    echo "FAIL - $label"
    FAILURES=$((FAILURES + 1))
  fi
}

if ! "$MAKE_DMG" "$STUB" "$OUT"; then
  echo "FAIL - make-dmg exited non-zero"
  exit 1
fi

check "the disk image exists" test -f "$OUT"
check "it is a compressed (UDZO) image" \
  bash -c "hdiutil imageinfo '$OUT' | grep -q 'Format: UDZO'"

MOUNT="$(hdiutil attach "$OUT" -nobrowse -noautoopen -readonly |
         grep -Eo '/Volumes/.+$' | tail -1)"
check "it mounts" test -d "$MOUNT"
check "the app is on it" test -d "$MOUNT/Chalant.app"
check "Applications is a symlink" test -L "$MOUNT/Applications"
check "that symlink points at /Applications" \
  bash -c "[ \"\$(readlink '$MOUNT/Applications')\" = /Applications ]"
check "the background rode along" test -f "$MOUNT/.background/background.tiff"
check "Finder wrote the window settings" test -f "$MOUNT/.DS_Store"

hdiutil detach "$MOUNT" -quiet; MOUNT=""

if [ "$FAILURES" -eq 0 ]; then
  echo "make-dmg: all checks passed"
else
  echo "make-dmg: $FAILURES check(s) failed"
fi
exit "$FAILURES"
```

```bash
chmod +x scripts/make-dmg-selftest
```

- [ ] **Step 2: Run it to verify it fails**

```bash
scripts/make-dmg-selftest
```

Expected: fails immediately, because `scripts/make-dmg` does not exist yet. The message will be a "No such file or directory" from the `"$MAKE_DMG"` invocation.

- [ ] **Step 3: Write the builder**

Create `scripts/make-dmg`:

```bash
#!/bin/bash
# Builds the disk image people download from the site: a black window
# with Chalant on the left, the Applications folder on the right, and
# one arrow between them. Drag, eject, done.
#
# Sparkle never sees this file. Updates take the zip, because Sparkle
# unpacks an archive in place and has no use for a Finder window.
#
# Give it an app that is ALREADY stapled. A ticket stapled after the
# image is built does not reach the copy inside it.
#
# Usage: scripts/make-dmg <path/to/Chalant.app> <path/to/out.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg <Chalant.app> <out.dmg>}"
OUT="${2:?usage: make-dmg <Chalant.app> <out.dmg>}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKGROUND="$REPO/packaging/dmg-background.tiff"
VOLNAME="Chalant"
WINDOW_W=660
WINDOW_H=420
ICON_AXIS=200          # matches "axis" in scripts/make-dmg-background.py
ICON_LEFT_X=165
ICON_RIGHT_X=495

[ -d "$APP" ] || { echo "make-dmg: no app bundle at $APP" >&2; exit 1; }
[ -f "$BACKGROUND" ] || {
  echo "make-dmg: no background at $BACKGROUND" >&2
  echo "make-dmg: run python3 scripts/make-dmg-background.py" >&2
  exit 1
}

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# hdiutil sizes a -srcfolder image to fit exactly, which leaves Finder
# no room to write the .DS_Store that carries every window setting
# below. Ask for the contents plus 50MB of slack.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 51200 ))

rm -f "$OUT"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" -ov -quiet "$WORK/rw.dmg"

MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -nobrowse -noautoopen |
         grep -Eo '/Volumes/.+$' | tail -1)"
[ -n "$MOUNT" ] || { echo "make-dmg: the image did not mount" >&2; exit 1; }

# Finder is the only thing that can set a window's background and icon
# positions, and AppleScript is the only way to ask it. This needs
# Automation permission for whatever terminal is running.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WINDOW_W)), $((120 + WINDOW_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Chalant.app" of container window to {$ICON_LEFT_X, $ICON_AXIS}
    set position of item "Applications" of container window to {$ICON_RIGHT_X, $ICON_AXIS}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT
then
  echo "make-dmg: Finder refused to style the window." >&2
  echo "make-dmg: if this was a permission error, allow this terminal" >&2
  echo "make-dmg: under System Settings, Privacy and Security, Automation." >&2
  exit 1
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$OUT" -quiet

echo "make-dmg: wrote $OUT ($(du -h "$OUT" | cut -f1))"
```

```bash
chmod +x scripts/make-dmg
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
scripts/make-dmg-selftest
```

Expected: seven `ok -` lines, then `make-dmg: all checks passed`, exit 0.

- [ ] **Step 5: Look at the real thing once**

Build a throwaway image from the installed app and open it, because no assertion above can tell you whether it looks right:

```bash
scripts/make-dmg ~/Downloads/installations/Chalant.app /tmp/chalant-eyeball.dmg
open /tmp/chalant-eyeball.dmg
```

The window must be 660x420, black, with Chalant on the left, Applications on the right, the arrow between them, and no toolbar. Eject it and delete `/tmp/chalant-eyeball.dmg` afterwards.

- [ ] **Step 6: Commit**

```bash
git add scripts/make-dmg scripts/make-dmg-selftest
git commit -m "feat(dmg): build the disk image people download

Staged folder, Applications symlink, Finder AppleScript for the window,
then UDZO. Takes an app that is already stapled, because a ticket
stapled afterwards never reaches the copy inside the image.

The selftest packages a stub bundle so it runs in seconds instead of
waiting on an archive."
```

---

### Task 3: Signing splits by configuration

**Files:**
- Create: `packaging/ExportOptions.plist`
- Modify: `project.yml` (settings block, version keys, the stale comment)
- Modify: `scripts/dev:9`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `packaging/ExportOptions.plist` for `xcodebuild -exportArchive`, and a single authoritative `DEVELOPMENT_TEAM` in `project.yml` that Task 4's preflight cross-checks and Task 7 edits.

**Note on the team ID:** it stays `WV59PZX4A3` through this task. That value is the free personal team and cannot produce a Developer ID build. Task 3 lays the structure so that Task 7 is a one-line change. Archives will fail to find a `Developer ID Application` identity until then, which is correct and expected.

- [ ] **Step 1: Split the identity in `project.yml`**

In the `Chalant` target's `settings` block, remove `CODE_SIGN_IDENTITY` from `base` and rewrite the comment above `DEVELOPMENT_TEAM`. The block currently reads:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cj.chalant
        CODE_SIGN_STYLE: Automatic
        # Stable dev-cert signing: ad-hoc re-signing made every rebuild
        # look like a new app, resetting Keychain and TCC grants.
        DEVELOPMENT_TEAM: WV59PZX4A3
        CODE_SIGN_IDENTITY: "Apple Development"
        SWIFT_VERSION: "5.9"
```

Change it to:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cj.chalant
        CODE_SIGN_STYLE: Automatic
        # One team, two identities, on purpose. Development signing is
        # local and fast and keeps a build's Keychain and TCC grants
        # stable across rebuilds. Developer ID is the only identity
        # Gatekeeper accepts on somebody else's Mac, and the only one
        # notarization will take, so it is reserved for archives.
        #
        # This value is the single source of truth for the team: both
        # packaging/ExportOptions.plist and scripts/dev read it, and
        # scripts/release refuses to run if they have drifted apart.
        DEVELOPMENT_TEAM: WV59PZX4A3
        SWIFT_VERSION: "5.9"
```

Then add a `configs` block as a sibling of `base`, immediately after `CODE_SIGN_ENTITLEMENTS`:

```yaml
      configs:
        Debug:
          CODE_SIGN_IDENTITY: "Apple Development"
        Release:
          CODE_SIGN_IDENTITY: "Developer ID Application"
```

Leave the `ChalantTests` target's settings untouched. Tests run under Debug and keep the development identity.

- [ ] **Step 2: Bump the version**

In the same `info.properties` block:

```yaml
        CFBundleShortVersionString: 1.11.0
        CFBundleVersion: "148"
```

- [ ] **Step 3: Verify the project still generates and Debug still builds**

```bash
xcodegen generate && scripts/dev
```

Expected: `BUILD SUCCEEDED` and Chalant relaunches. Debug is unaffected by everything above.

- [ ] **Step 4: Give `scripts/dev` one source of truth**

`scripts/dev:9` currently reads:

```bash
TEAM="${CHALANT_TEAM:-WV59PZX4A3}"
```

Replace it with:

```bash
# project.yml is the only place the team is written down. A second copy
# here is a second thing to forget on the day the team changes.
TEAM="${CHALANT_TEAM:-$(awk '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)}"
```

And update the comment block at the top of the file, which currently claims the team is "the same pinned team project.yml ships with" as though that were a coincidence:

```bash
# Dev loop: regenerate, build, relaunch. Signs Debug with the same
# development identity project.yml pins, so a dev build and an installed
# build do not fight over Keychain and TCC grants. Override the team
# with CHALANT_TEAM=<id> if you sign with a different one.
```

- [ ] **Step 5: Verify the lookup returns the right team**

```bash
awk '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml
```

Expected: `WV59PZX4A3` exactly, with no quotes or trailing whitespace.

- [ ] **Step 6: Write the export options**

Create `packaging/ExportOptions.plist`. Note that `docs/RELEASING.md` has instructed using this file since before it existed, which is why release practice drifted to using the xcarchive's app directly.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Distribution outside the App Store, signed with Developer ID.
       This is the only export method whose output notarization will
       accept. -->
  <key>method</key>
  <string>developer-id</string>

  <!-- Must match DEVELOPMENT_TEAM in project.yml. scripts/release
       compares the two and stops if they have drifted. -->
  <key>teamID</key>
  <string>WV59PZX4A3</string>

  <!-- Chalant's entitlements are hardened runtime entitlements rather
       than capability entitlements, so no provisioning profile is
       involved and Xcode can resolve the identity on its own. -->
  <key>signingStyle</key>
  <string>automatic</string>

  <key>destination</key>
  <string>export</string>
</dict>
</plist>
```

- [ ] **Step 7: Prove the Release configuration now demands Developer ID**

```bash
xcodebuild -showBuildSettings -scheme Chalant -configuration Release 2>/dev/null \
  | grep -E "^\s+(CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|ENABLE_HARDENED_RUNTIME) "
xcodebuild -showBuildSettings -scheme Chalant -configuration Debug 2>/dev/null \
  | grep -E "^\s+CODE_SIGN_IDENTITY "
```

Expected: Release shows `CODE_SIGN_IDENTITY = Developer ID Application`, `DEVELOPMENT_TEAM = WV59PZX4A3`, `ENABLE_HARDENED_RUNTIME = YES`. Debug shows `CODE_SIGN_IDENTITY = Apple Development`.

- [ ] **Step 8: Commit**

```bash
git add project.yml scripts/dev packaging/ExportOptions.plist
git commit -m "feat(sign): Developer ID on Release, development on Debug

Archives are the only build that has to satisfy Gatekeeper on somebody
else's Mac, so they are the only build that pays for a Developer ID
identity. Debug keeps the fast local one.

ExportOptions.plist exists for the first time. RELEASING.md has been
telling people to pass it to -exportArchive since before it was written,
which is why the real ritual drifted to using the xcarchive directly.

The team ID now lives in exactly one file. scripts/dev reads it and
scripts/release will refuse to run when the plist has drifted from it."
```

---

### Task 4: One command releases

**Files:**
- Create: `scripts/release`
- Consumes: `scripts/make-dmg` (Task 2), `packaging/ExportOptions.plist` and `project.yml`'s `DEVELOPMENT_TEAM` (Task 3)

**Interfaces:**
- Consumes: `scripts/make-dmg <app> <out.dmg>` from Task 2.
- Produces: `scripts/release <version> [--notes-file PATH] [--skip-tests] [--dry-run]`. Task 7 runs it.

**The point of this script is its last stage.** A release that reports success without Gatekeeper having been asked is the exact failure mode this whole project exists to end. Stage 16 is not a formality.

- [ ] **Step 1: Write the script**

Create `scripts/release`:

```bash
#!/bin/bash
# The whole release, one command:
#
#   scripts/release 1.11.0 --notes-file RELEASE-NOTES-1.11.0.md
#
# Bumps, tests, archives, exports with Developer ID, notarizes, staples,
# builds the disk image, notarizes that too, signs the update for
# Sparkle, writes the appcast, tags, publishes, kicks the Pages build,
# and only then asks Gatekeeper whether any of it actually worked.
#
# It reports success if and only if spctl agrees. Everything else in
# here is bookkeeping; that last check is the point.
#
# Flags:
#   --notes-file PATH   release notes for the GitHub release
#   --skip-tests        for a re-run after notarization failed
#   --dry-run           preflight only, changes nothing
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

VERSION=""
NOTES_FILE=""
SKIP_TESTS=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -*) echo "release: unknown flag $1" >&2; exit 1 ;;
    *)  VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || { echo "usage: scripts/release <version> [--notes-file PATH] [--skip-tests] [--dry-run]" >&2; exit 1; }

TAG="v$VERSION"
BUILD_DIR="$REPO/build"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Chalant.app"
DMG="$BUILD_DIR/Chalant-$VERSION.dmg"
ZIP="$BUILD_DIR/Chalant-$VERSION.zip"
ZIP_STABLE="$BUILD_DIR/Chalant.zip"
NOTARY_PROFILE="chalant-notary"
GH_REPO="chetanjon/chalant"

step() { echo; echo "==> $*"; }
die()  { echo "release: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1/16
step "Preflight"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main. The appcast is invisible to users from anywhere else."
git rev-parse "$TAG" >/dev/null 2>&1 && die "$TAG already exists"

for tool in xcodegen gh hdiutil tiffutil xcrun ditto; do
  command -v "$tool" >/dev/null || die "missing $tool"
done

# The wrong sign_update is one directory away and signs with the legacy
# DSA algorithm, which produces a signature Sparkle rejects.
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*artifacts/sparkle/Sparkle/bin/sign_update' \
  -not -path '*old_dsa_scripts*' -type f 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || die "sign_update not found. Build once so SPM resolves Sparkle."

TEAM="$(awk '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)"
[ -n "$TEAM" ] || die "no DEVELOPMENT_TEAM in project.yml"

PLIST_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :teamID' packaging/ExportOptions.plist)"
[ "$PLIST_TEAM" = "$TEAM" ] || \
  die "packaging/ExportOptions.plist says team $PLIST_TEAM, project.yml says $TEAM"

security find-identity -v -p codesigning | grep -q "Developer ID Application" || \
  die "no Developer ID Application identity in the Keychain. Enrollment is not done, or the certificate was never created."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || \
  die "no notary credentials. Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id $TEAM --password <app-specific>"

[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die "no notes file at $NOTES_FILE"

CURRENT_BUILD="$(awk '/CFBundleVersion:/ {gsub(/"/,"",$2); print $2; exit}' project.yml)"
NEXT_BUILD=$((CURRENT_BUILD + 1))

echo "    version   $VERSION (build $CURRENT_BUILD -> $NEXT_BUILD)"
echo "    team      $TEAM"
echo "    notary    $NOTARY_PROFILE"
echo "    notes     ${NOTES_FILE:-none}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo; echo "release: preflight passed. Nothing changed (--dry-run)."
  exit 0
fi

# ---------------------------------------------------------------- 2/16
step "Bump to $VERSION (build $NEXT_BUILD)"
# Both keys, always. Sparkle compares CFBundleVersion, users read the
# short string, and xcodegen rewrites Info.plist from these two.
sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: $VERSION/" project.yml
sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$NEXT_BUILD\"/" project.yml
xcodegen generate --quiet

# ---------------------------------------------------------------- 3/16
if [ "$SKIP_TESTS" -eq 0 ]; then
  step "Tests"
  xcodebuild test -scheme Chalant -destination 'platform=macOS' 2>&1 \
    | grep -E "Test Suite .* (passed|failed)|error:|\*\* TEST" | tail -20
  # grep swallows xcodebuild's status, so ask git-independent PIPESTATUS
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "tests failed"
else
  step "Tests skipped (--skip-tests)"
fi

# ---------------------------------------------------------------- 4/16
step "Archive and export"
rm -rf "$BUILD_DIR/Chalant.xcarchive" "$EXPORT_DIR"
xcodebuild archive -scheme Chalant -configuration Release \
  -archivePath "$BUILD_DIR/Chalant.xcarchive" \
  -allowProvisioningUpdates >/dev/null || die "archive failed"

xcodebuild -exportArchive -archivePath "$BUILD_DIR/Chalant.xcarchive" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist packaging/ExportOptions.plist \
  -allowProvisioningUpdates >/dev/null || die "export failed"

[ -d "$APP" ] || die "no app at $APP after export"

# ---------------------------------------------------------------- 5/16
step "Verify the signature before Apple sees it"
# Five minutes of notary queue is a slow way to learn the identity was
# wrong, so check here instead.
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1)"
echo "$AUTHORITY" | grep -q "Developer ID Application" || \
  die "signed with the wrong identity: $AUTHORITY"
codesign -dvv "$APP" 2>&1 | grep -q "flags=.*runtime" || \
  die "hardened runtime is not enabled. Notarization will reject this."

# ---------------------------------------------------------------- 6/16
step "Zip"
rm -f "$ZIP" "$ZIP_STABLE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ---------------------------------------------------------------- 7/16
step "Notarize the app (this waits on Apple)"
notarize() {
  local path="$1"
  local out
  if ! out="$(xcrun notarytool submit "$path" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
    echo "$out"
    local id
    id="$(echo "$out" | grep -Eo '[0-9a-f-]{36}' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" \
      --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -60
    die "notarization failed for $path"
  fi
  echo "$out" | grep -q "status: Accepted" || {
    echo "$out"
    local id
    id="$(echo "$out" | grep -Eo '[0-9a-f-]{36}' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" \
      --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -60
    die "notarization was not Accepted for $path"
  }
  echo "    accepted"
}
notarize "$ZIP"

# ---------------------------------------------------------------- 8/16
step "Staple the app"
# The ticket goes inside the bundle so a first launch works with no
# network. Everything downstream must use this stapled copy.
xcrun stapler staple "$APP" || die "stapling failed"

# The zip was made before stapling, so it holds an unstapled app.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cp "$ZIP" "$ZIP_STABLE"

# ---------------------------------------------------------------- 9/16
step "Build the disk image"
scripts/make-dmg "$APP" "$DMG"

# --------------------------------------------------------------- 10/16
step "Sign, notarize and staple the disk image"
# A stapled app inside an unsigned, unnotarized image still gets the
# image itself blocked on arrival, so the container needs its own pass.
codesign --sign "Developer ID Application" --timestamp "$DMG" || die "could not sign the dmg"
notarize "$DMG"
xcrun stapler staple "$DMG" || die "stapling the dmg failed"

# --------------------------------------------------------------- 11/16
step "Sign the update for Sparkle"
SIGN_OUT="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIGN_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || die "could not read sign_update output: $SIGN_OUT"
echo "    $LENGTH bytes"

# --------------------------------------------------------------- 12/16
step "Write the appcast"
PUB_DATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
python3 - "$VERSION" "$NEXT_BUILD" "$LENGTH" "$ED_SIG" "$PUB_DATE" <<'PYEOF'
import sys
from pathlib import Path

version, build, length, sig, pub_date = sys.argv[1:6]
path = Path("docs/appcast.xml")
text = path.read_text()

item = f"""        <item>
            <title>{version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/chetanjon/chalant/releases/download/v{version}/Chalant-{version}.zip" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
        </item>
"""

anchor = "        <title>Chalant</title>\n"
if anchor not in text:
    sys.exit("appcast: could not find the channel title to insert after")
if f"<title>{version}</title>" in text:
    sys.exit(f"appcast: {version} is already in there")

path.write_text(text.replace(anchor, anchor + item, 1))
print(f"    inserted {version} at the top")
PYEOF

# --------------------------------------------------------------- 13/16
step "Commit, tag, push"
git add project.yml docs/appcast.xml Chalant/Info.plist 2>/dev/null || true
git commit -q -m "chore: $VERSION"
git tag "$TAG"
git push -q origin main --tags

# --------------------------------------------------------------- 14/16
step "Publish"
NOTES_ARG=(--notes "$VERSION")
[ -n "$NOTES_FILE" ] && NOTES_ARG=(--notes-file "$NOTES_FILE")
gh release create "$TAG" "$DMG" "$ZIP" "$ZIP_STABLE" \
  --title "$VERSION" "${NOTES_ARG[@]}"

# --------------------------------------------------------------- 15/16
step "Kick the Pages build"
# Pages does not always rebuild on a push, and the appcast is invisible
# to every user's update check until it does.
gh api -X POST "repos/$GH_REPO/pages/builds" >/dev/null && echo "    queued"

# --------------------------------------------------------------- 16/16
step "Ask Gatekeeper"
APP_VERDICT="$(spctl -a -vvv -t install "$APP" 2>&1)"
echo "$APP_VERDICT" | sed 's/^/    /'
echo "$APP_VERDICT" | grep -q "accepted" || die "GATEKEEPER REJECTED THE APP. The release is published but it is not safe to hand out."
echo "$APP_VERDICT" | grep -q "Notarized Developer ID" || die "the app is accepted but not as Notarized Developer ID."

DMG_VERDICT="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1)"
echo "$DMG_VERDICT" | sed 's/^/    /'
echo "$DMG_VERDICT" | grep -q "accepted" || die "GATEKEEPER REJECTED THE DISK IMAGE."

xcrun stapler validate "$APP" >/dev/null || die "the app has no stapled ticket"
xcrun stapler validate "$DMG" >/dev/null || die "the disk image has no stapled ticket"

echo
echo "release: $VERSION is out, notarized, and Gatekeeper agrees."
echo "release: https://github.com/$GH_REPO/releases/tag/$TAG"
```

```bash
chmod +x scripts/release
```

- [ ] **Step 2: Run the preflight and confirm it stops for the right reason**

```bash
scripts/release 1.11.0 --dry-run
```

Expected: it fails at the Developer ID check with

```
release: no Developer ID Application identity in the Keychain. Enrollment is not done, or the certificate was never created.
```

That is the correct result today. It proves every earlier check passed (clean tree, on the right branch, tag free, tools present, `sign_update` found, teams in agreement) and that the script correctly refuses to build something Gatekeeper would reject.

- [ ] **Step 3: Prove the drift check works**

Temporarily break the plist and confirm the script catches it:

```bash
/usr/libexec/PlistBuddy -c "Set :teamID WRONGTEAM99" packaging/ExportOptions.plist
scripts/release 1.11.0 --dry-run
/usr/libexec/PlistBuddy -c "Set :teamID WV59PZX4A3" packaging/ExportOptions.plist
```

Expected: the middle command fails with `packaging/ExportOptions.plist says team WRONGTEAM99, project.yml says WV59PZX4A3`, and the third restores it. Confirm with `git diff --exit-code packaging/ExportOptions.plist` that nothing was left changed.

- [ ] **Step 4: Prove the appcast writer inserts at the top and refuses duplicates**

Run the stage 12 Python against a copy, without touching the real file:

```bash
mkdir -p /tmp/appcast-check/docs && cp docs/appcast.xml /tmp/appcast-check/docs/
cd /tmp/appcast-check && sed -n '/^python3 - /,/^PYEOF$/p' "$REPO/scripts/release" > /dev/null
```

Simpler and sufficient: extract the heredoc body into `/tmp/appcast-check/insert.py` by hand, then:

```bash
cd /tmp/appcast-check
python3 insert.py 1.11.0 148 16750000 FAKESIG== "Tue, 12 Aug 2026 09:00:00 -0700"
head -12 docs/appcast.xml
python3 insert.py 1.11.0 148 16750000 FAKESIG== "Tue, 12 Aug 2026 09:00:00 -0700"
cd "$REPO" && rm -rf /tmp/appcast-check
```

Expected: the first run prints `inserted 1.11.0 at the top` and `head` shows the new item directly under `<title>Chalant</title>`, above 1.10.5. The second run exits non-zero with `appcast: 1.11.0 is already in there`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release
git commit -m "feat(release): one command, and it asks Gatekeeper before it claims success

Sixteen stages. Fifteen of them are bookkeeping and the sixteenth is the
point: spctl has to say accepted and Notarized Developer ID, and both
tickets have to validate, or the script reports failure no matter how
well everything else went.

Folds in the traps that were previously remembered by hand: the Pages
build that must be kicked after every release, sign_update living in
DerivedData with a legacy-DSA twin one directory away, and the appcast
being invisible to users from anywhere but main."
```

---

### Task 5: The copy stops apologizing

**Files:**
- Modify: `docs/index.html:328-331` (the get section), `docs/index.html:376-390` (the note section), `docs/index.html:416` (the JS href)
- Modify: `README.md:9-17`, `README.md:127`, `README.md:131`, `README.md:143`
- Modify: `chetanjon/homebrew-chalant` `Casks/chalant.rb` (separate repo, via `gh`)

**Interfaces:**
- Consumes: the DMG asset name `Chalant-<version>.dmg` published by Task 4 stage 14.
- Produces: nothing other tasks read.

**Asset naming:** the release carries `Chalant-1.11.0.dmg`, `Chalant-1.11.0.zip` and `Chalant.zip`. The site links `releases/latest/download/Chalant-1.11.0.dmg`, which breaks on the next release. Use a stable name instead: Task 4 stage 14 must also upload a copy named `Chalant.dmg`. **Add that now**, in `scripts/release`, before editing any copy.

- [ ] **Step 1: Give the DMG a stable name too**

In `scripts/release`, add next to the other artifact paths:

```bash
DMG_STABLE="$BUILD_DIR/Chalant.dmg"
```

After stage 10's stapling, add:

```bash
cp "$DMG" "$DMG_STABLE"
```

and change stage 14's upload line to:

```bash
gh release create "$TAG" "$DMG" "$DMG_STABLE" "$ZIP" "$ZIP_STABLE" \
  --title "$VERSION" "${NOTES_ARG[@]}"
```

The copy is made after stapling so both files carry the ticket.

- [ ] **Step 2: Rewrite the download section of the site**

`docs/index.html:328-331` currently reads:

```html
    <a class="button" id="get" href="https://github.com/chetanjon/chalant/releases/latest/download/Chalant.zip">Download for Mac</a>
    <div class="fine">apple silicon · macos 14+ · free</div>
    <div class="fine">unzip · drag chalant to applications · first open: system settings, privacy and security, open anyway</div>
```

Replace with:

```html
    <a class="button" id="get" href="https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg">Download for Mac</a>
    <div class="fine">apple silicon · macos 14+ · free</div>
    <div class="fine">open · drag chalant to applications</div>
```

- [ ] **Step 3: Fix the JavaScript that duplicates that URL**

`docs/index.html:416` holds the same link a second time for the download counter. Change:

```js
      "https://github.com/chetanjon/chalant/releases/latest/download/Chalant.zip";
```

to:

```js
      "https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg";
```

Verify no third copy survives:

```bash
grep -n "Chalant.zip" docs/index.html
```

Expected: no output.

- [ ] **Step 4: Rewrite the "First open" section**

`docs/index.html:376-390` is a section headed "First open" whose entire premise is the ceremony. The ceremony is gone, so the section's heading and first three sentences go with it. Its remaining content (public source, dictation, what reaches the internet, the Chat tab disclaimer) is good and survives. Replace the whole `<section class="note">` block with:

```html
  <section class="note">
    <h2>What it asks of you</h2>
    <p>
      Chalant is signed with a Developer ID certificate and notarized by
      Apple, so it opens the way any Mac app opens. Homebrew works too:
      <code>brew install --cask chetanjon/chalant/chalant</code>.
      From then on the island mentions a new version once and one click
      installs it in place. The
      <a href="https://github.com/chetanjon/chalant">source is public</a>,
      speech recognition uses Apple standard dictation, and Chalant itself only asks the
      internet whether a newer version exists, and for the update when you say yes. The optional Chat tab is
      a small built-in browser where you sign in to Claude, ChatGPT, or
      Gemini with your own account; Chalant is not affiliated with
      Anthropic, OpenAI, or Google. Everything can be switched off.
    </p>
  </section>
```

- [ ] **Step 5: Check the site still renders and holds no stale claim**

```bash
grep -n -i -E "unsigned|no-quarantine|open anyway|move to trash|ceremony" docs/index.html
open docs/index.html
```

Expected: no grep output. The page opens with a working Download button and the fine print reads `open · drag chalant to applications`.

- [ ] **Step 6: Rewrite the README download block**

`README.md:11-17` currently reads (line 11 is one long paragraph; only its first half changes):

```markdown
[**Download Chalant.zip**](https://github.com/chetanjon/chalant/releases/latest/download/Chalant.zip), always the newest build. Apple Silicon, macOS 14+, free. (Release notes live on the [releases page](https://github.com/chetanjon/chalant/releases/latest).) Or through Homebrew:

```
brew install --cask chetanjon/chalant/chalant --no-quarantine
```

Homebrew is the quiet route: the flag above skips the first-open challenge, because macOS only challenges what it saw arrive from a browser. Downloading the zip instead: unzip, drag Chalant to Applications, open it, and macOS asks once. Click Done, not Move to Trash, then System Settings, Privacy and Security, scroll down, Open Anyway. Chalant is unsigned because it is free and independent. After that, updates take care of themselves:
```

Replace everything from `[**Download Chalant.zip**]` through `Chalant is unsigned because it is free and independent.` with:

```markdown
[**Download Chalant.dmg**](https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg), always the newest build. Apple Silicon, macOS 14+, free. (Release notes live on the [releases page](https://github.com/chetanjon/chalant/releases/latest).) Or through Homebrew:

```
brew install --cask chetanjon/chalant/chalant
```

Open the disk image, drag Chalant to Applications, open it. Chalant is signed with a Developer ID certificate and notarized by Apple, so there is no warning to click past and no flag to pass.
```

Keep the rest of that paragraph, starting at `After that, updates take care of themselves:`, exactly as it is.

- [ ] **Step 7: Fix the three remaining README claims**

`README.md:127` currently reads:

```markdown
- Unsigned; the first open needs one Open Anyway.
```

Replace with:

```markdown
- Signed with a Developer ID certificate and notarized by Apple.
```

`README.md:131` currently opens:

```markdown
The honest version, since you are running an unsigned app that can touch a lot.
```

Replace with:

```markdown
The honest version, since this app can touch a lot.
```

`README.md:143` currently reads:

```markdown
- Distribution: the Homebrew cask is live (`brew install --cask chetanjon/chalant/chalant --no-quarantine`); a notarized build if enrollment ever earns its $99. The landing page is [live](https://chetanjon.github.io/chalant/).
```

Replace with:

```markdown
- Distribution: signed and notarized since 1.11.0, as a disk image and through the Homebrew cask (`brew install --cask chetanjon/chalant/chalant`). The landing page is [live](https://chetanjon.github.io/chalant/).
```

- [ ] **Step 8: Check nothing stale survives in the README**

```bash
grep -n -i -E "unsigned|no-quarantine|open anyway|move to trash|earns its" README.md
```

Expected: no output.

- [ ] **Step 9: Rewrite the Homebrew cask**

The cask lives in the separate `chetanjon/homebrew-chalant` repo. Fetch, rewrite, push through `gh`:

```bash
gh api repos/chetanjon/homebrew-chalant/contents/Casks/chalant.rb --jq .content | base64 -d > /tmp/chalant.rb
```

Replace the whole file with:

```ruby
cask "chalant" do
  version :latest
  sha256 :no_check

  url "https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg"
  name "Chalant"
  desc "AI-native dynamic island for the Mac notch"
  homepage "https://chetanjon.github.io/chalant/"

  # The app keeps itself current via Sparkle since 1.0.86.
  auto_updates true

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Chalant.app"
end
```

The `caveats` block goes entirely. It existed only to explain how to click past a Gatekeeper warning, and there is no longer a warning.

Push it:

```bash
SHA="$(gh api repos/chetanjon/homebrew-chalant/contents/Casks/chalant.rb --jq .sha)"
gh api -X PUT repos/chetanjon/homebrew-chalant/contents/Casks/chalant.rb \
  -f message="chalant 1.11.0: notarized, so the quarantine flag and the caveats go" \
  -f content="$(base64 -i /tmp/chalant.rb | tr -d '\n')" \
  -f sha="$SHA" >/dev/null && echo "cask updated"
rm /tmp/chalant.rb
```

**Do this step only after Task 7 has published the release.** Pointing the cask at `Chalant.dmg` before that asset exists breaks every `brew install` in the meantime.

- [ ] **Step 10: Commit the site and README**

```bash
git add docs/index.html README.md scripts/release
git commit -m "docs: stop apologizing for being unsigned

Five places said it. The site's fine print made people memorize a
three-step ceremony, the install command asked strangers to pass
--no-quarantine, and the roadmap still promised notarization 'if
enrollment ever earns its \$99'.

The 'First open' section is gone as a section. Its privacy content was
the good half and it moves up under a heading that is about what the
app asks of you rather than what macOS asks about the app.

Also gives the disk image a stable Chalant.dmg name alongside the
versioned one, because the site links latest/download and cannot know
the version."
```

---

### Task 6: Rewrite the release ritual

**Files:**
- Modify: `docs/RELEASING.md` (whole file)

**Interfaces:**
- Consumes: `scripts/release` (Task 4), `packaging/ExportOptions.plist` (Task 3).
- Produces: nothing other tasks read.

- [ ] **Step 1: Rewrite the document**

Replace the whole of `docs/RELEASING.md` with:

````markdown
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
   notary profile resolving, and `packaging/ExportOptions.plist`
   agreeing with `project.yml` about the team. `--dry-run` stops here.
2. **Bump** both version keys in `project.yml` and regenerate. Both,
   always: Sparkle compares `CFBundleVersion` and users read
   `CFBundleShortVersionString`, and `xcodegen` rewrites Info.plist
   from these two, so a version set in the plist alone disappears.
3. **Tests.** `--skip-tests` exists for a re-run after a notarization
   failure, not for a hurry.
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
without Gatekeeper having agreed is the failure this project spent a
year shipping.

## Which artifact is for whom

- `Chalant.dmg` and `Chalant-<version>.dmg`: people arriving from the
  site and from Homebrew. Never referenced by the appcast.
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

## Doing it by hand

If the script is not the answer, the stages above are ordinary commands
and can be run one at a time. Two traps worth carrying over:

- `sign_update` is not on `PATH`. It lives at
  `~/Library/Developer/Xcode/DerivedData/Chalant-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`,
  and there is a second copy one directory down under
  `old_dsa_scripts/` that signs with the legacy DSA algorithm and
  produces a signature Sparkle rejects.
- Nothing is notarized until `xcrun stapler validate` says so. A build
  that Apple accepted but that was never stapled will still work
  online and fail on a machine with no network.
````

- [ ] **Step 2: Check no stale instruction survives**

```bash
grep -n -i -E "ExportOptions.plist that does not exist|Notarize per Apple|unsigned" docs/RELEASING.md
```

Expected: no output. Then confirm the file references a real path:

```bash
test -f packaging/ExportOptions.plist && echo "the plist RELEASING.md names exists"
```

- [ ] **Step 3: Commit**

```bash
git add docs/RELEASING.md
git commit -m "docs: rewrite the release ritual around scripts/release

The old document told you to pass -exportArchive an ExportOptions.plist
that was not in the repo, and hand-waved notarization in a parenthesis.
Both are now real."
```

---

### Task 7: Enroll, cut over, ship

**Files:**
- Modify: `project.yml` (`DEVELOPMENT_TEAM` only)
- Modify: `packaging/ExportOptions.plist` (`teamID` only)
- Create: `RELEASE-NOTES-1.11.0.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the 1.11.0 release.

**Blocked** until Apple approves the Developer Program enrollment and the founder hands over the team ID and an app-specific password.

- [ ] **Step 1: Confirm enrollment landed**

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected: one identity, with the paid team's ID in parentheses. If it is absent, the certificate has not been created yet: open Xcode, Settings, Accounts, select the team, Manage Certificates, `+`, Developer ID Application.

- [ ] **Step 2: Read the team ID off the certificate rather than trusting a note**

```bash
security find-identity -v -p codesigning \
  | grep "Developer ID Application" | grep -Eo '\([A-Z0-9]{10}\)' | tr -d '()'
```

Use that exact value in the next step.

- [ ] **Step 3: Store the notary credentials**

```bash
xcrun notarytool store-credentials "chalant-notary" \
  --apple-id j.chetan9009@gmail.com \
  --team-id <the team id from Step 2> \
  --password <the app-specific password>
xcrun notarytool history --keychain-profile chalant-notary | head -5
```

Expected: the history command succeeds. An empty history is fine and expected; what matters is that it does not error on credentials.

- [ ] **Step 4: Cut the team over in both files**

```bash
sed -i '' "s/DEVELOPMENT_TEAM: WV59PZX4A3/DEVELOPMENT_TEAM: <new team>/" project.yml
/usr/libexec/PlistBuddy -c "Set :teamID <new team>" packaging/ExportOptions.plist
xcodegen generate
```

Then confirm they agree, which is what stage 1 of the release checks:

```bash
awk '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml
/usr/libexec/PlistBuddy -c 'Print :teamID' packaging/ExportOptions.plist
```

Expected: the same string twice.

- [ ] **Step 5: Confirm Debug still builds under the new team**

```bash
scripts/dev
```

Expected: `BUILD SUCCEEDED` and Chalant relaunches. macOS will re-ask for permissions here, because the identity changed. This is the reset the release notes describe, arriving early.

- [ ] **Step 6: Write the release notes**

Create `RELEASE-NOTES-1.11.0.md`:

```markdown
# Chalant 1.11.0

Chalant is signed with a Developer ID certificate and notarized by
Apple. It opens the way any Mac app opens.

Until today it was signed with a development certificate, which is a
certificate for running an app on the machine that built it. Gatekeeper
rejected it on every other Mac, which is why installing meant unzipping,
dragging, clicking past a warning with no Open button, and then going to
System Settings, Privacy and Security, and scrolling to the bottom for
Open Anyway. The Homebrew route needed `--no-quarantine`, which asked
you to disable a macOS protection on this project's word.

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
grants themselves: your settings, your saved things and your streaks
are untouched.

## Nothing else changed

No feature moved. This release is the certificate and the packaging.
```

- [ ] **Step 7: Land the branch on main**

```bash
git add -A && git commit -q -m "chore: cut over to the Developer ID team"
git checkout main && git merge --no-ff notarized-distribution -m "Merge notarized-distribution: signed by Apple, and a disk image to match"
```

- [ ] **Step 8: Release**

```bash
scripts/release 1.11.0 --notes-file RELEASE-NOTES-1.11.0.md
```

Expected, at the end:

```
==> Ask Gatekeeper
    /path/to/Chalant.app: accepted
    source=Notarized Developer ID
    ...
release: 1.11.0 is out, notarized, and Gatekeeper agrees.
```

If notarization is rejected, the log the script prints names the binary at fault. Fix it and re-run with `--skip-tests`.

- [ ] **Step 9: Update the Homebrew cask**

Now that `Chalant.dmg` exists on the release, run Task 5 Step 9.

- [ ] **Step 10: Prove it from a user's position**

The whole point, verified the way a stranger would meet it:

```bash
cd /tmp
curl -L -o Chalant.dmg https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg
xattr -w com.apple.quarantine "0083;00000000;Safari;" Chalant.dmg   # what a browser would attach
spctl -a -vvv -t open --context context:primary-signature Chalant.dmg
open Chalant.dmg
```

Expected: `accepted`, `source=Notarized Developer ID`. The image mounts with no warning. Drag the app to Applications and open it: macOS shows the ordinary *"Chalant is an app downloaded from the Internet. Are you sure you want to open it?"* sheet with a working Open button. It must **not** show *"Apple could not verify Chalant is free of malware"*. That second dialog is the one this release exists to remove.

```bash
spctl -a -vvv -t install /Applications/Chalant.app
xcrun stapler validate /Applications/Chalant.app
```

Expected: `accepted`, `source=Notarized Developer ID`, and `The validate action worked!`.

- [ ] **Step 11: Prove existing users cross the change**

On a machine still running 1.10.5, or from a copy of it, open the dashboard's General section and click Install. Sparkle allows the identity change because `SUPublicEDKey` did not, and the EdDSA check passes on its own. Confirm it lands on 1.11.0 and relaunches.

- [ ] **Step 12: Install locally and re-grant**

```bash
open /Applications/Chalant.app
```

Walk the permissions back through: hold the notch and talk (Microphone), ask it to summarize the screen (Screen Recording), snap a window (Accessibility), check the day (Calendars and Reminders), confirm the weather line returns (Location). Each should ask once and then work. This is the release notes' claim, tested.
````

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: signing split (Task 3), ExportOptions (Task 3), notary credentials (Task 7 Step 3), the release script's sixteen stages (Task 4), the DMG and its background (Tasks 1 and 2), all six copy locations (Task 5), RELEASING.md (Task 6), sequencing and the enrollment gate (Task 7), and all four of the spec's verification criteria (Task 7 Steps 10 and 11). The spec's "out of scope" list is respected: no permissions pane, no in-app banner, no change to `SUPublicEDKey`.

**One correction against the spec.** The spec put the DMG icons at 40% and 60% of the window width. At 128pt in a 660pt window those centres are 132pt apart, so the icons would nearly touch and leave no room for the arrow. This plan uses 25% and 75% (x=165 and x=495), which leaves a 202pt gap. Fix that line in the spec.

**One gap the spec did not name.** The site links `releases/latest/download/`, which needs a version-independent asset name, so the release must publish `Chalant.dmg` alongside `Chalant-<version>.dmg`. Task 5 Step 1 adds it.

**Type consistency.** `scripts/make-dmg <app> <out.dmg>` is defined in Task 2 and called with exactly that shape in Task 4 stage 9. `packaging/dmg-background.tiff` is written in Task 1 and read at that exact path in Task 2. `DEVELOPMENT_TEAM` is parsed by the identical `awk` expression in `scripts/dev` (Task 3), `scripts/release` (Task 4) and Task 7's verification. The notary profile is the string `chalant-notary` in Task 4, Task 6 and Task 7.
