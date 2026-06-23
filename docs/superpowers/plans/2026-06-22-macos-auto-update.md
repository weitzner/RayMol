# macOS Auto-Update (Sparkle) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-app update checking + one-click download/install to the macOS RayMol DMG build via Sparkle, ship a 1.1.0 release to GitHub Releases, and point the marketing site at it.

**Architecture:** Sparkle 2.x SPM dependency linked into the macOS slice only of the shared `PyMOLViewer` target. A small `RayMolUpdater` wraps `SPUStandardUpdaterController`. The existing `make_dmg.sh` (Developer-ID sign + notarize + staple) is unchanged; a new `publish_release.sh` EdDSA-signs the DMG, regenerates `appcast.xml`, and publishes both to GitHub Releases on `javierbq/RayMol`.

**Tech Stack:** Swift/SwiftUI, xcodegen (`project.yml`), Sparkle 2.x, Apple codesign/notarytool, `gh` CLI, bash.

## Global Constraints

- Sparkle code is macOS-only: every Swift use wrapped in `#if os(macOS)`; the SPM dependency is `platformFilter: macOS` so the iOS slice never links it.
- Bundle id `io.raymol.RayMol`, Team ID `VT99UQUQ89`, `minimumSystemVersion` macOS `13.0`, Apple-silicon only (`ARCHS: arm64`).
- This release: `MARKETING_VERSION = 1.1.0`, `CURRENT_PROJECT_VERSION = 5` (must exceed installed build 4 — Sparkle compares on `CFBundleVersion`).
- Feed URL (stable): `https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml`.
- Hosting repo for release assets: `javierbq/RayMol` (public).
- Signing keys (Developer ID + Sparkle EdDSA private key) live only in the login keychain; never commit them.
- Do not change the signing logic in `make_dmg.sh` — Sparkle's helpers are sealed by its existing deepest-first Mach-O loop.

---

### Task 1: Add Sparkle dependency (macOS-only) and regenerate the project

**Files:**
- Modify: `swiftui/project.yml` (add top-level `packages:` block + macOS-filtered dependency on the `PyMOLViewer` target)

**Interfaces:**
- Produces: `import Sparkle` available to the macOS slice; Sparkle's `bin/generate_keys` and `bin/sign_update` tools downloaded into `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.

- [ ] **Step 1:** Add to `swiftui/project.yml` a top-level block:
```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
```
- [ ] **Step 2:** Add to the `PyMOLViewer` target's `dependencies:` list (currently `[]`):
```yaml
    dependencies:
      - package: Sparkle
        platformFilter: macOS
```
- [ ] **Step 3:** Regenerate the Xcode project:
```bash
cd swiftui && xcodegen generate
```
Expected: "Created project at .../PyMOLViewer.xcodeproj".
- [ ] **Step 4:** Resolve packages so Sparkle (and its tools) download:
```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -resolvePackageDependencies
```
Expected: resolves `sparkle-project/Sparkle` at 2.6.x.
- [ ] **Step 5:** Locate the Sparkle tools (used in later tasks):
```bash
find ~/Library/Developer/Xcode/DerivedData -path "*Sparkle/bin/generate_keys" 2>/dev/null | head -1
```
Expected: a path is printed.
- [ ] **Step 6:** Commit.
```bash
git add swiftui/project.yml && git commit -m "build: add Sparkle SPM dependency (macOS only)"
```

---

### Task 2: Generate the Sparkle EdDSA signing key

**Files:** none (key stored in login keychain; public key captured for Task 5)

**Interfaces:**
- Produces: a base64 EdDSA **public key** string, recorded for `SUPublicEDKey` in Task 5. Private key is created in the keychain under Sparkle's account.

- [ ] **Step 1:** Run `generate_keys` (path from Task 1 Step 5). If a key already exists it prints the existing public key:
```bash
GEN=$(find ~/Library/Developer/Xcode/DerivedData -path "*Sparkle/bin/generate_keys" 2>/dev/null | head -1)
"$GEN"
```
Expected: prints `A public key has been generated...` followed by a base64 string, OR `<SUPublicEDKey> already exists` with the key. **If macOS shows a keychain GUI prompt, this is the point to click "Always Allow" — pause and ask the user if running headless.**
- [ ] **Step 2:** Record the printed base64 public key for Task 5. (No commit — nothing on disk.)

---

### Task 3: Add the updater controller

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/RayMolUpdater.swift`

**Interfaces:**
- Produces: `final class RayMolUpdater: ObservableObject` with `let controller: SPUStandardUpdaterController` and `func checkForUpdates()`. Consumed by Task 4.

- [ ] **Step 1:** Create `swiftui/PyMOLViewer/Shared/RayMolUpdater.swift`:
```swift
#if os(macOS)
import Foundation
import Sparkle

/// Wraps Sparkle's standard updater for the Developer-ID/DMG macOS build.
/// Started automatically; reads SUFeedURL / SUPublicEDKey from Info.plist.
final class RayMolUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → begins scheduled background checks immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
#endif
```
- [ ] **Step 2:** Commit.
```bash
git add swiftui/PyMOLViewer/Shared/RayMolUpdater.swift
git commit -m "feat(macos): add Sparkle updater controller"
```

---

### Task 4: Wire the "Check for Updates…" menu item

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLApp.swift` (the `@main` App struct, inside `.commands { }`)

**Interfaces:**
- Consumes: `RayMolUpdater` from Task 3.

- [ ] **Step 1:** Near the top of the `App` struct's properties, add a macOS-only updater instance:
```swift
#if os(macOS)
    @StateObject private var updater = RayMolUpdater()
#endif
```
- [ ] **Step 2:** Inside the existing `.commands { }` block, add a macOS-only command group:
```swift
#if os(macOS)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
#endif
```
- [ ] **Step 3:** Build to verify Sparkle links and the macOS app compiles (this is the main validation gate):
```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit.
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLApp.swift
git commit -m "feat(macos): add Check for Updates menu item"
```

---

### Task 5: Inject Sparkle Info.plist keys + bump version

**Files:**
- Modify: `swiftui/project.yml` — bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; add Sparkle keys to the existing macOS post-build `plutil` step (the one that force-sets `CFBundleName`).

**Interfaces:**
- Produces: a built macOS `RayMol.app` whose Info.plist contains `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`.

- [ ] **Step 1:** In `swiftui/project.yml`, set `MARKETING_VERSION: "1.1.0"` and `CURRENT_PROJECT_VERSION: 5` on the `PyMOLViewer` target.
- [ ] **Step 2:** In the macOS post-build script step that runs `plutil -replace CFBundleName ...`, append (using the `<PUBKEY>` from Task 2):
```bash
          /usr/bin/plutil -replace SUFeedURL -string "https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml" "$PLIST"
          /usr/bin/plutil -replace SUPublicEDKey -string "<PUBKEY>" "$PLIST"
          /usr/bin/plutil -replace SUEnableAutomaticChecks -bool true "$PLIST"
          /usr/bin/plutil -replace SUScheduledCheckInterval -integer 86400 "$PLIST"
          echo "Sparkle keys -> $PLIST"
```
- [ ] **Step 3:** Regenerate and rebuild, then confirm the keys land in the built Info.plist:
```bash
cd swiftui && xcodegen generate
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
APP=$(find ~/Library/Developer/Xcode/DerivedData/PyMOLViewer-*/Build/Products/Release -maxdepth 1 -name RayMol.app | head -1)
plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" && plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist"
```
Expected: the feed URL and the public key print; `BUILD SUCCEEDED`.
- [ ] **Step 4:** Commit.
```bash
git add swiftui/project.yml
git commit -m "feat(macos): inject Sparkle Info.plist keys; bump to 1.1.0 (build 5)"
```

---

### Task 6: Add the publish script + appcast

**Files:**
- Create: `swiftui/publish_release.sh`
- Create: `appcast.xml` (repo root — source of truth, also uploaded as a release asset)

**Interfaces:**
- Consumes: a notarized `RayMol-1.1.0.dmg` at repo root (produced in Task 7); Sparkle's `sign_update` tool.
- Produces: a published GitHub Release `v1.1.0` on `javierbq/RayMol` with `RayMol-1.1.0.dmg` and `appcast.xml` as assets.

- [ ] **Step 1:** Create `swiftui/publish_release.sh`:
```bash
#!/bin/bash
# publish_release.sh — EdDSA-sign the notarized DMG, regenerate appcast.xml, and
# publish the DMG + appcast to GitHub Releases on javierbq/RayMol.
# Run AFTER make_dmg.sh. Usage:  VERSION=1.1.0 BUILD=5 bash swiftui/publish_release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="javierbq/RayMol"
VERSION="${VERSION:?Set VERSION, e.g. 1.1.0}"
BUILD="${BUILD:?Set BUILD (CFBundleVersion), e.g. 5}"
DMG="$ROOT/RayMol-$VERSION.dmg"
APPCAST="$ROOT/appcast.xml"
[ -f "$DMG" ] || { echo "ERROR: $DMG not found (run make_dmg.sh first)"; exit 1; }

SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle/bin/sign_update' 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "ERROR: sign_update not found; resolve Sparkle package first"; exit 1; }

echo "== EdDSA-sign the DMG =="
# Emits e.g.:  sparkle:edSignature="..." length="12345"
SIGFRAG="$("$SIGN_UPDATE" "$DMG")"
echo "  $SIGFRAG"

URL="https://github.com/$REPO/releases/download/v$VERSION/RayMol-$VERSION.dmg"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
NOTESLINK="https://github.com/$REPO/releases/tag/v$VERSION"

echo "== Write appcast.xml =="
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>RayMol</title>
    <link>https://github.com/$REPO/releases/latest/download/appcast.xml</link>
    <description>RayMol macOS updates</description>
    <language>en</language>
    <item>
      <title>RayMol $VERSION</title>
      <sparkle:releaseNotesLink>$NOTESLINK</sparkle:releaseNotesLink>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGFRAG />
    </item>
  </channel>
</rss>
XML
echo "  wrote $APPCAST"

echo "== Publish GitHub release v$VERSION =="
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" "$APPCAST" -R "$REPO" --clobber
else
  gh release create "v$VERSION" "$DMG" "$APPCAST" -R "$REPO" \
    --title "RayMol $VERSION" \
    --notes "Automatic updates are here. RayMol now checks for new versions and installs them with one click. Built on the open-source PyMOL engine."
fi
echo "DONE → https://github.com/$REPO/releases/tag/v$VERSION"
```
- [ ] **Step 2:** Make it executable and commit (appcast.xml is generated at publish time in Task 8; commit the script now):
```bash
chmod +x swiftui/publish_release.sh
git add swiftui/publish_release.sh
git commit -m "build: add publish_release.sh (EdDSA sign + appcast + gh release)"
```

---

### Task 7: Build the notarized 1.1.0 DMG

**Files:** none (produces `RayMol-1.1.0.dmg` at repo root)

**Interfaces:**
- Consumes: Developer ID cert + `RayMol-notary` profile (both confirmed present).
- Produces: `RayMol-1.1.0.dmg` — Developer-ID-signed, notarized, stapled.

- [ ] **Step 1:** Run the existing DMG build (it builds the Release app fresh, so it picks up Sparkle + the new Info.plist keys):
```bash
cd /Users/jcastellanos/repos/RayMol
DEVID="Developer ID Application: Javier Castellanos (VT99UQUQ89)" \
NOTARY_PROFILE=RayMol-notary VERSION=1.1.0 \
bash swiftui/make_dmg.sh
```
Expected: ends with `DONE → .../RayMol-1.1.0.dmg` and `spctl` reporting `accepted` / `Notarized Developer ID`.
- [ ] **Step 2:** Verify Sparkle's helpers were sealed by the existing signing loop:
```bash
codesign --verify --deep --strict --verbose=2 build_dmg/RayMol.app 2>&1 | tail -3
```
Expected: `valid on disk` / `satisfies its Designated Requirement` — no errors. (No commit; binary artifact.)

---

### Task 8: Publish the release

**Files:** Modify `appcast.xml` (generated/overwritten by the script)

**Interfaces:**
- Consumes: `RayMol-1.1.0.dmg` (Task 7), `publish_release.sh` (Task 6).
- Produces: GitHub Release `v1.1.0` on `javierbq/RayMol` with DMG + appcast; the stable feed URL now resolves.

- [ ] **Step 1:** Run the publish script:
```bash
cd /Users/jcastellanos/repos/RayMol
VERSION=1.1.0 BUILD=5 bash swiftui/publish_release.sh
```
Expected: prints the EdDSA signature fragment, writes `appcast.xml`, and `DONE → .../releases/tag/v1.1.0`.
- [ ] **Step 2:** Verify the feed URL resolves and serves the appcast:
```bash
curl -sL https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml | head -20
```
Expected: the appcast XML with `<sparkle:shortVersionString>1.1.0` and an `edSignature`.
- [ ] **Step 3:** Commit the appcast source-of-truth.
```bash
git add appcast.xml
git commit -m "release: RayMol 1.1.0 appcast"
```

---

### Task 9: Point the marketing site at 1.1.0

**Files:**
- Modify: `/Users/jcastellanos/repos/raymol-site/index.html` (3 download links + size/version notes)

**Interfaces:** none.

- [ ] **Step 1:** In `raymol-site/index.html`, replace all three occurrences of
  `https://github.com/javierbq/raymol-site/releases/download/v1.0.0/RayMol-1.0.0.dmg`
  with
  `https://github.com/javierbq/RayMol/releases/download/v1.1.0/RayMol-1.1.0.dmg`.
- [ ] **Step 2:** Update the size/version note text near line 81/314 to reflect the new size (read actual DMG size with `ls -lh RayMol-1.1.0.dmg`) and keep "macOS 13+ · Apple Silicon".
- [ ] **Step 3:** Commit and push the site (its publish is git-push to `main`):
```bash
cd /Users/jcastellanos/repos/raymol-site
git add index.html && git commit -m "Point download at RayMol 1.1.0 (auto-update release)"
git push origin main
```
Expected: push succeeds.

---

### Task 10: Merge the feature to master

**Files:** none.

- [ ] **Step 1:** Verify the feature branch builds clean (already done in Task 4/5) and the release is live (Task 8). Then merge:
```bash
cd /Users/jcastellanos/repos/RayMol
git checkout master
git merge --no-ff feat/macos-auto-update -m "Merge: macOS auto-update via Sparkle (1.1.0)"
```
- [ ] **Step 2:** Push master:
```bash
git push origin master
```
Expected: push succeeds.

---

## Self-Review

- **Spec coverage:** Sparkle dependency (T1), EdDSA key (T2), updater + menu (T3/T4), Info.plist keys + version bump (T5), publish script + appcast (T6), DMG build (T7), release (T8), site (T9), merge (T10). All design sections covered.
- **Placeholders:** `<PUBKEY>` (T5) and `$SIGFRAG`/size (T6/T9) are runtime values produced by earlier tasks, not unspecified TODOs — each has the exact command that yields it.
- **Type consistency:** `RayMolUpdater` / `checkForUpdates()` / `controller` consistent across T3↔T4. Version `1.1.0`/build `5` consistent across T5/T7/T8.
- **Risk:** the only step that can require human action is a GUI keychain "Allow" prompt at T2 (EdDSA key) — flagged in-task.
