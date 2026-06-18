# RayMol App Store Submission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship RayMol to the Mac App Store and iOS App Store as one free universal app (`io.raymol.RayMol`), phased macOS-first.

**Architecture:** The existing single universal Xcode target (`PyMOLViewer`, built via XcodeGen from `swiftui/project.yml`, embedding CPython 3.13 + a Metal core in `libpymol_core.a`) gains App Sandbox + Hardened Runtime + entitlements + a privacy manifest, is renamed to `RayMol.app` under bundle ID `io.raymol.RayMol`, and is archived/uploaded to App Store Connect. macOS is submitted first; iOS follows with a guideline-2.5.2 fallback switch.

**Tech Stack:** Swift/SwiftUI, Metal, XcodeGen (`project.yml`), `xcodebuild`, embedded BeeWare CPython 3.13 (iOS) + standalone Python 3.13 (macOS), `codesign`, App Store Connect, TestFlight.

## Global Constraints

- Bundle ID (both platforms): `io.raymol.RayMol`
- Product/bundle name: `RayMol` (rename from `PyMOLViewer`); display name `RayMol`
- Dev team: `VT99UQUQ89`; `CODE_SIGN_STYLE = Automatic`; Apple Distribution
- `ENABLE_APP_SANDBOX = YES`, `ENABLE_HARDENED_RUNTIME = YES` (Release)
- App category: `public.app-category.education`; pricing free, no IAP
- `ITSAppUsesNonExemptEncryption = NO`
- MUST NOT use entitlements `com.apple.security.cs.allow-jit`, `...allow-unsigned-executable-memory`; avoid `...disable-library-validation` (sign all embedded binaries same-team instead)
- Never merge to `master` of upstream `schrodinger/*`; push only to `origin` (`javierbq/RayMol`); commit only when the user asks
- Regenerate the Xcode project with `xcodegen generate` (run in `swiftui/`) after editing `project.yml`
- macOS app build: `bash swiftui/build_macos.sh` then `xcodebuild -scheme PyMOLViewer_macOS`; iOS sim build: `xcodebuild -scheme PyMOLViewer_iOS -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`
- Privacy policy → `raymol.io/privacy`; support + marketing → `raymol.io`

---

## Phase 1 — Shared groundwork (identity, sandbox, privacy)

### Task 1: Bundle ID + product rename + signing/sandbox settings  **[agent]**

**Files:**
- Modify: `swiftui/project.yml` (settings)
- Modify: `swiftui/build_macos.sh`, `swiftui/build_ios.sh`, `swiftui/build.sh` (any `PyMOLViewer.app` / product-name path refs)

**Interfaces:**
- Produces: bundle ID `io.raymol.RayMol`, product `RayMol`, on-disk `RayMol.app`; Release config with team + automatic signing + sandbox/hardened-runtime flags + `CODE_SIGN_ENTITLEMENTS` pointing at the Task 2 file path.

- [ ] **Step 1: Edit `project.yml` identity + signing.** In the top `options:` block set `bundleIdPrefix: io.raymol`. In `targets: PyMOLViewer: settings: base:` set:
```yaml
        PRODUCT_NAME: RayMol
        PRODUCT_BUNDLE_IDENTIFIER: io.raymol.RayMol
```
Add a `configs: Release:` block under that target (merge with the existing Release entry):
```yaml
        Release:
          SWIFT_OPTIMIZATION_LEVEL: -O
          DEVELOPMENT_TEAM: VT99UQUQ89
          CODE_SIGN_STYLE: Automatic
          ENABLE_HARDENED_RUNTIME: YES
          ENABLE_APP_SANDBOX: YES
          CODE_SIGN_ENTITLEMENTS: PyMOLViewer/RayMol.entitlements
```
(The entitlements file is created in Task 2; referencing it now is fine — the build won't run until Task 2.)

- [ ] **Step 2: Update build scripts + harness refs.** In `swiftui/build_macos.sh`, `swiftui/build_ios.sh`, `swiftui/build.sh`, replace any literal `PyMOLViewer.app` with `RayMol.app` and any `PRODUCT_NAME=PyMOLViewer` assumption. Grep first:
```bash
grep -rn "PyMOLViewer.app\|org.pymol.viewer" swiftui/*.sh
```
Replace `org.pymol.viewer` → `io.raymol.RayMol` in those scripts.

- [ ] **Step 3: Regenerate + build macOS to verify it still compiles under the new identity.**
```bash
cd swiftui && xcodegen generate
bash build_macos.sh
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath build_mac_dd build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. (Debug config has no signing/sandbox yet — Task 2 adds those; Debug build only confirms the rename didn't break compilation.)

- [ ] **Step 4: Verify the built bundle identity.**
```bash
APP=$(find swiftui/build_mac_dd/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist"   # io.raymol.RayMol
/usr/bin/plutil -extract CFBundleName raw "$APP/Contents/Info.plist"          # RayMol
```
Expected: `io.raymol.RayMol` and `RayMol`.

- [ ] **Step 5: Commit (after user OK per commit-only-when-asked).**
```bash
git add swiftui/project.yml swiftui/build_macos.sh swiftui/build_ios.sh swiftui/build.sh
git commit -m "build(appstore): rename to RayMol.app + io.raymol.RayMol bundle id, Release signing/sandbox settings"
```

---

### Task 2: Entitlements file + signed sandboxed Release build  **[agent]**

**Files:**
- Create: `swiftui/PyMOLViewer/RayMol.entitlements`
- Modify: `swiftui/project.yml` (only if entitlements path needs platform variants)

**Interfaces:**
- Consumes: `CODE_SIGN_ENTITLEMENTS` wired in Task 1.
- Produces: a signed, sandboxed, hardened-runtime `RayMol.app` for the Release config.

- [ ] **Step 1: Create `swiftui/PyMOLViewer/RayMol.entitlements`** (exact contents):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)io.raymol.RayMol</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Regenerate + Release build (signed).** This requires being logged into Xcode with the `VT99UQUQ89` account so automatic signing can mint a development/distribution profile.
```bash
cd swiftui && xcodegen generate
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Release -derivedDataPath build_mac_rel build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If signing fails with "no profile", the user must open the project in Xcode once and let automatic signing register the App ID (see Task 15 note).

- [ ] **Step 3: Verify sandbox + hardened runtime + entitlements on the binary.**
```bash
APP=$(find swiftui/build_mac_rel/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "app-sandbox|network.client|user-selected"
codesign -dvvv "$APP" 2>&1 | grep -E "flags=.*runtime"   # hardened runtime present
```
Expected: the three entitlement keys present; `flags` line includes `runtime`.

- [ ] **Step 4: Launch the signed sandboxed build and confirm it renders a molecule** (smoke test before the full audit in Task 5).
```bash
open -nF "$APP" --args
sleep 6 && pkill -f "RayMol.app/Contents/MacOS"
```
Expected: window appears (manually confirm a structure loads via the empty-state Open/Fetch, or AUTOCMD). No immediate sandbox crash.

- [ ] **Step 5: Commit.**
```bash
git add swiftui/PyMOLViewer/RayMol.entitlements swiftui/project.yml
git commit -m "build(appstore): App Sandbox + hardened-runtime entitlements (network, user-selected files, keychain)"
```

---

### Task 3: Sign all embedded native binaries same-team (avoid library-validation disable)  **[agent]**

**Files:**
- Modify: `swiftui/project.yml` (the framework embed/sign `postBuildScripts` / `postCompileScripts` block, currently signing only `Frameworks/*.framework`)

**Interfaces:**
- Consumes: signed Release build from Task 2.
- Produces: every embedded `.framework`, `.dylib`, `.so` inside the bundle signed with `$EXPANDED_CODE_SIGN_IDENTITY`, so the hardened runtime loads them without `disable-library-validation`.

- [ ] **Step 1: Locate the current embed-sign script** in `project.yml` (the block near the `find "$CODESIGNING_FOLDER_PATH/Frameworks" -name "*.framework" -exec /usr/bin/codesign ...` line) and broaden it to also sign loadable Python extensions and dylibs:
```bash
if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
  # frameworks (existing)
  find "$CODESIGNING_FOLDER_PATH/Frameworks" -name "*.framework" -exec \
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none "{}" \; || true
  # embedded Python extension modules + dylibs (NEW)
  find "$CODESIGNING_FOLDER_PATH" \( -name "*.so" -o -name "*.dylib" \) -exec \
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none "{}" \; || true
fi
```

- [ ] **Step 2: Regenerate + Release build.**
```bash
cd swiftui && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Release -derivedDataPath build_mac_rel build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify deep signature validity (catches any unsigned embedded code).**
```bash
APP=$(find swiftui/build_mac_rel/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5
# Confirm no .so/.dylib left unsigned:
find "$APP" \( -name "*.so" -o -name "*.dylib" \) -exec codesign -v {} \; 2>&1 | grep -v "valid on disk" | head
```
Expected: `valid on disk` / `satisfies its Designated Requirement`; the second command prints nothing (all signed).

- [ ] **Step 4: Launch signed build and exercise the embedded interpreter** (load a structure, run a `python`-tab command) to confirm dylibs load under hardened runtime without library-validation kills.
```bash
APP=$(find swiftui/build_mac_rel/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
open -nF "$APP"; sleep 8
log show --last 30s --predicate 'eventMessage CONTAINS "library validation"' 2>/dev/null | tail -5
pkill -f "RayMol.app/Contents/MacOS"
```
Expected: no "library validation" / "code signature" denial messages.

- [ ] **Step 5: Commit.**
```bash
git add swiftui/project.yml
git commit -m "build(appstore): sign all embedded .so/.dylib same-team (no library-validation disable)"
```

---

### Task 4: Sandbox-safe file paths — `fetch` dir + subprocess audit  **[agent]**

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (engine init — set a container-relative `fetch_path`)
- Audit (read-only grep): `modules/pymol/`, `modules/chempy/` for `subprocess`/`os.system`/`os.popen`/`os.fork` on reachable paths

**Interfaces:**
- Consumes: signed sandboxed build (Task 2/3).
- Produces: `fetch` writes inside the container; documented list of any subprocess call sites and their gate.

- [ ] **Step 1: Add a failing check (a Swift unit-style assertion via a debug command).** Since there's no XCTest harness for the engine, the "test" is a runtime assertion: launch the sandboxed app, run `fetch 1ubq, async=0` then `print(cmd.get("fetch_path"))`, and confirm the path is under the app container (`…/Library/Containers/io.raymol.RayMol/…`), not `~` or cwd. First confirm it currently FAILS (defaults to a non-container path) by launching the Task 3 build and reading the feedback log after a `fetch`.

- [ ] **Step 2: Set the fetch path at engine startup.** In `PyMOLEngine` initialization (after the core is ready, where other one-time `cmd.set` calls live), add:
```swift
// App Sandbox: downloads must land in the container. Point PyMOL's fetch_path
// at Application Support (always writable in-sandbox).
runPython(
    "import os\n" +
    "from pymol import cmd as _c\n" +
    "_d = os.path.join(os.path.expanduser('~/Library/Application Support'), 'RayMol', 'fetch')\n" +
    "os.makedirs(_d, exist_ok=True)\n" +
    "_c.set('fetch_path', _d, quiet=1)"
)
```
(In-sandbox, `~` already resolves to the container, so this stays inside it.)

- [ ] **Step 3: Rebuild + verify the fetch path is container-relative.**
```bash
cd swiftui && bash build_macos.sh && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Release -derivedDataPath build_mac_rel build 2>&1 | tail -3
```
Launch, `fetch 1ubq, async=0`, confirm the file appears under `~/Library/Containers/io.raymol.RayMol/Data/Library/Application Support/RayMol/fetch/`.

- [ ] **Step 4: Audit subprocess use and record findings.**
```bash
grep -rn "subprocess\|os.system\|os.popen\|os.fork\|Popen" modules/pymol modules/chempy | grep -v test | tee /tmp/raymol_subprocess_audit.txt
```
For each hit, note in the commit message whether it's on a reachable RayMol feature path. If any is reachable (e.g. an external-tool invocation), gate it behind a capability check or disable on the sandboxed build. (Expected: PyMOL core rarely spawns processes; most hits are in unused plugins.)

- [ ] **Step 5: Commit.**
```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "fix(appstore): container-relative fetch_path for sandbox; subprocess audit notes"
```

---

### Task 5: Full sandbox-denial audit pass  **[agent + you to spot-check GUI]**

**Files:** none (verification task; fixes loop back into Tasks 2/4 entitlements/paths as needed)

- [ ] **Step 1: Launch the signed sandboxed Release build with Console denial capture running.**
```bash
APP=$(find swiftui/build_mac_rel/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
log stream --predicate 'process == "RayMol" AND (eventMessage CONTAINS "deny" OR senderImagePath CONTAINS "Sandbox")' > /tmp/raymol_sandbox.log 2>&1 &
LOGPID=$!
open -nF "$APP"
```

- [ ] **Step 2: Exercise every feature** (you drive the GUI; agent can drive via `PYMOL_AUTOCMD` where possible): Open a local `.pdb`/`.cif` via the panel; Fetch `1ubq`; show cartoon/sticks/spheres/surface/mesh/labels; apply a theme; run a measurement; build/export a movie; Save Image (PNG) + Save Session (.pse); Copy to clipboard; type a command + a `python` snippet; (Raymond with demo key if convenient).

- [ ] **Step 3: Stop capture and review denials.**
```bash
sleep 2; kill $LOGPID; pkill -f "RayMol.app/Contents/MacOS"
sort -u /tmp/raymol_sandbox.log | grep -iE "deny|sandbox" | head -50
```
Expected after fixes: no `deny` lines for normal feature use. For each remaining denial, either add the matching entitlement (Task 2) or reroute the path (Task 4), then re-run this task.

- [ ] **Step 4: Record the clean-audit result** in a short note appended to the spec's risks section (or a `docs/superpowers/notes/2026-06-17-sandbox-audit.md`) listing what was exercised and that the log was clean. Commit that note.

---

### Task 6: Privacy manifest + encryption declaration  **[agent]**

**Files:**
- Create: `swiftui/PyMOLViewer/PrivacyInfo.xcprivacy`
- Modify: `swiftui/project.yml` (add the privacy manifest to resources if not auto-included; add `INFOPLIST_KEY` for encryption)

**Interfaces:**
- Produces: a bundled `PrivacyInfo.xcprivacy` and `ITSAppUsesNonExemptEncryption=NO` in Info.plist.

- [ ] **Step 1: Create `swiftui/PyMOLViewer/PrivacyInfo.xcprivacy`** with the minimal honest declaration (UserDefaults reason; no tracking). Adjust the API-types array after Step 3's audit if more required-reason APIs are found:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```
(`NSPrivacyCollectedDataTypes` stays empty in the *manifest*; the AI "User Content" disclosure lives in the App Store Connect nutrition labels — Task 15 — which is where third-party-sent data is declared.)

- [ ] **Step 2: Ensure the manifest is bundled.** In `project.yml`, the target's `sources: - path: PyMOLViewer` glob already includes it; confirm by building and checking it lands at the bundle root. Add the encryption key to `settings: base:`:
```yaml
        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
```

- [ ] **Step 3: Audit for additional required-reason APIs** and extend the manifest if any are genuinely used by app code (not just dormant in the embedded stdlib):
```bash
grep -rn "stat(\|getmtime\|st_mtime\|systemUptime\|mach_absolute_time\|FileManager.*creationDate\|volumeAvailableCapacity" swiftui/PyMOLViewer | head
```
For real hits, add the matching `NSPrivacyAccessedAPICategory*` + reason code. (Embedded-Python stdlib usage of these is exempt from the *app's* manifest unless app/first-party Swift code calls them on a user-visible path — keep the set minimal and true.)

- [ ] **Step 4: Build both platforms; confirm the manifest is at the bundle root and Info.plist has the encryption key.**
```bash
cd swiftui && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Release -derivedDataPath build_mac_rel build 2>&1 | tail -3
APP=$(find swiftui/build_mac_rel/Build/Products -name "RayMol.app" -maxdepth 3 | head -1)
ls "$APP/Contents/Resources/PrivacyInfo.xcprivacy" && /usr/bin/plutil -extract ITSAppUsesNonExemptEncryption raw "$APP/Contents/Info.plist"
```
Expected: file exists; value `NO`.

- [ ] **Step 5: Commit.**
```bash
git add swiftui/PyMOLViewer/PrivacyInfo.xcprivacy swiftui/project.yml
git commit -m "privacy(appstore): privacy manifest (UserDefaults reason, no tracking) + encryption-exempt declaration"
```

---

### Task 7: raymol.io privacy policy + support page text  **[agent drafts → you publish]**

**Files:**
- Create: `docs/raymol.io/privacy.md`, `docs/raymol.io/support.md`

- [ ] **Step 1: Write `docs/raymol.io/privacy.md`** covering: what RayMol is; that **no data is collected by default**; the **optional** Raymond feature sends the user's prompts + current structure context to the **user-configured** LLM provider (Anthropic or Google Vertex) only while in use, governed by that provider's policy; PDB IDs are sent to RCSB when fetching; the LLM API key is stored locally in the Keychain; no analytics, no tracking, no ads; contact email. Date it 2026-06-17.

- [ ] **Step 2: Write `docs/raymol.io/support.md`** — a short support page: what RayMol is, how to get help (contact email / GitHub issues at `github.com/javierbq/RayMol`), and a one-line "RayMol is an independent fork of open-source PyMOL (© Schrödinger, LLC), BSD-licensed."

- [ ] **Step 3: Commit; hand off to you to publish at `raymol.io/privacy` and `raymol.io`.**
```bash
git add docs/raymol.io/privacy.md docs/raymol.io/support.md
git commit -m "docs(appstore): privacy policy + support page text for raymol.io"
```
**[you — raymol.io]** Publish these two pages so `raymol.io/privacy` and `raymol.io` resolve before submission.

---

## Phase 2 — macOS submission

### Task 8: App icon completeness + marketing icon  **[agent verifies, you supply art if missing]**

**Files:**
- Modify: `swiftui/PyMOLViewer/…/Assets.xcassets/AppIcon.appiconset` (add any missing sizes incl. 1024×1024)

- [ ] **Step 1: Audit the icon set** against required slots for macOS (16–1024) and iOS (incl. 1024 marketing, no alpha):
```bash
find swiftui/PyMOLViewer -name "Contents.json" -path "*AppIcon*" -exec cat {} \;
```
List missing sizes.

- [ ] **Step 2: Generate any missing sizes from the master RayMol icon** (`swiftui/PyMOLViewer/Resources/RayMol.svg` or the existing largest PNG) with `sips`/`rsvg-convert`; ensure the 1024 marketing icon has **no alpha**:
```bash
# example for the 1024 marketing icon from a source PNG:
sips -s format png -z 1024 1024 SOURCE.png --out icon_1024.png
sips -s formatOptions default --setProperty hasAlpha no icon_1024.png || true
```
Place into the appiconset and update `Contents.json`.

- [ ] **Step 3: Build; confirm Xcode emits no missing-icon warnings.**
```bash
cd swiftui && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Release -derivedDataPath build_mac_rel build 2>&1 | grep -i "appicon\|icon" | head
```
Expected: no "missing" warnings.

- [ ] **Step 4: Commit.**
```bash
git add swiftui/PyMOLViewer
git commit -m "assets(appstore): complete app icon set incl. 1024 marketing icon"
```

---

### Task 9: Generate store screenshots  **[agent]**

**Files:**
- Create: `docs/appstore/screenshots/` (generated PNGs)

- [ ] **Step 1: macOS screenshots** via the PID-exact harness — load a few showcase scenes (themed cartoon; ray-traced surface; sticks close-up) and capture at a clean window size. Save 3–5 to `docs/appstore/screenshots/macos/`.

- [ ] **Step 2: iPhone 6.9" + iPad 13" screenshots** via simulator:
```bash
SIM_IPAD=5B38444F-5A63-4AF5-AD57-5C029012CDAF   # iPad Pro 13 M5
# build+install the iOS app (Release), launch with showcase AUTOCMD, simctl io screenshot
```
Capture matching showcase scenes; save to `docs/appstore/screenshots/ipad/` and `…/iphone/` (use an iPhone 16 Pro Max sim for 6.9").

- [ ] **Step 3: Verify exact pixel dimensions** match App Store requirements per device class (`sips -g pixelWidth -g pixelHeight <png>`); note them in a `docs/appstore/screenshots/README.md`.

- [ ] **Step 4: Commit; you pick the final set.**
```bash
git add docs/appstore/screenshots
git commit -m "assets(appstore): candidate store screenshots (macOS, iPhone 6.9, iPad 13)"
```

---

### Task 10: Listing text + review notes  **[agent drafts]**

**Files:**
- Create: `docs/appstore/listing.md` (name, subtitle, description, keywords, promo text, what's-new, URLs), `docs/appstore/review-notes.md`

- [ ] **Step 1: Draft `docs/appstore/listing.md`** — app name "RayMol", subtitle, a description emphasizing native Metal molecular visualization + ray tracing + PyMOL scripting, keyword list, promotional text, "what's new" for 1.0, support/marketing URL `raymol.io`, privacy URL `raymol.io/privacy`, copyright crediting PyMOL/Schrödinger.

- [ ] **Step 2: Draft `docs/appstore/review-notes.md`** — the guideline-2.5.2 framing (command line = documented PyMOL scripting driving the bundled engine; Raymond optional/off-by-default, requires the user's own LLM key), plus a **demo key + step-by-step** for the reviewer to test Raymond, and a statement that the app is fully functional without it.

- [ ] **Step 3: Commit.**
```bash
git add docs/appstore/listing.md docs/appstore/review-notes.md
git commit -m "docs(appstore): listing copy + App Review notes (2.5.2 framing, Raymond demo steps)"
```

---

### Task 11: macOS archive + export  **[agent]**

**Files:**
- Create: `swiftui/archive_appstore.sh`

- [ ] **Step 1: Write `swiftui/archive_appstore.sh`** to archive + export the macOS slice for App Store, parameterized by platform:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-macOS}"   # macOS | iOS
xcodegen generate
[ "$DEST" = "macOS" ] && bash build_macos.sh
SCHEME=$([ "$DEST" = "macOS" ] && echo PyMOLViewer_macOS || echo PyMOLViewer_iOS)
DESTSPEC=$([ "$DEST" = "macOS" ] && echo 'generic/platform=macOS' || echo 'generic/platform=iOS')
xcodebuild -project PyMOLViewer.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "$DESTSPEC" -archivePath "build_archive/RayMol-$DEST.xcarchive" archive
cat > /tmp/exportOptions-$DEST.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>VT99UQUQ89</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "build_archive/RayMol-$DEST.xcarchive" \
  -exportOptionsPlist /tmp/exportOptions-$DEST.plist -exportPath "build_export/$DEST"
echo "exported to build_export/$DEST"
```
(`method` may need to be `app-store` on older Xcode; the script uses `app-store-connect` for current Xcode.)

- [ ] **Step 2: Run the macOS archive.** Requires Xcode logged into `VT99UQUQ89`.
```bash
chmod +x swiftui/archive_appstore.sh && swiftui/archive_appstore.sh macOS 2>&1 | tail -8
```
Expected: `** ARCHIVE SUCCEEDED **` then an exported `.pkg` under `swiftui/build_export/macOS/`.

- [ ] **Step 3: Verify the exported package is App Store-signed.**
```bash
ls swiftui/build_export/macOS/*.pkg
```
Expected: a `RayMol.pkg` exists.

- [ ] **Step 4: Commit the script.**
```bash
git add swiftui/archive_appstore.sh
git commit -m "build(appstore): archive+export script (App Store method, macOS/iOS)"
```

---

### Task 12: App Store Connect record + macOS upload + submit  **[you — Apple portal]**

**Files:** none (portal work; agent provides the exact checklist + drafted text from Tasks 7/10)

- [ ] **Step 1: Register the App ID** `io.raymol.RayMol` at developer.apple.com → Identifiers (or let Xcode automatic-signing create it on first archive). Enable the App Sandbox + Keychain Sharing capabilities matching the entitlements.
- [ ] **Step 2: Create the app record** in App Store Connect: name "RayMol" (use the listing.md text), primary language, bundle ID `io.raymol.RayMol`, SKU. Add the **macOS** platform.
- [ ] **Step 3: Fill metadata** from `docs/appstore/listing.md`: subtitle, description, keywords, promo text, support URL `raymol.io`, marketing URL, **privacy policy URL `raymol.io/privacy`**, category Education, age rating questionnaire (→ 4+), copyright.
- [ ] **Step 4: Complete App Privacy nutrition labels** from `docs/appstore/review-notes.md`/spec §3: declare **User Content → App Functionality, not linked, not tracking** (the Raymond path); everything else "Data Not Collected."
- [ ] **Step 5: Upload the build** — Xcode → Organizer → select the `RayMol-macOS.xcarchive` → "Distribute App" → App Store Connect → Upload (or `xcrun altool --upload-app -f build_export/macOS/RayMol.pkg -t macos --apiKey … --apiIssuer …`).
- [ ] **Step 6: TestFlight smoke test** — once processed, install the macOS TestFlight build; re-run the Task 5 feature sweep on the *delivered* build.
- [ ] **Step 7: Attach review notes + submit for review** (paste `docs/appstore/review-notes.md`). Wait for approval before Phase 3.

---

## Phase 3 — iOS submission

### Task 13: iOS guideline-2.5.2 fallback switch  **[agent]**

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (gate the command-line input + Raymond entry on iOS)
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (SettingsSheet — hide the experimental AI toggle when restricted)
- Modify: `swiftui/project.yml` (define the flag, default OFF)

**Interfaces:**
- Produces: a compile condition `RAYMOL_IOS_APPSTORE_RESTRICTED` that, when active, removes the user command-line field + all Raymond UI from the iOS build only.

- [ ] **Step 1: Define the flag (default off = surfaces shipped).** In `project.yml` under the target `settings: base:`, leave `SWIFT_ACTIVE_COMPILATION_CONDITIONS` as-is for the default build; document that setting `RAYMOL_IOS_APPSTORE_RESTRICTED` (e.g. via an `xcconfig` or `-D` flag) enables restricted mode. Add a commented Release-iOS variant in `project.yml` the user can flip.

- [ ] **Step 2: Gate the command-line input on iOS.** In `ContentView.swift`, wrap the iOS command-field usage (the CommandPanel input on the compact/iPad layouts) so it's omitted under the flag:
```swift
#if os(iOS) && RAYMOL_IOS_APPSTORE_RESTRICTED
// command-line input hidden for App Store (guideline 2.5.2)
#else
CommandPanel()
#endif
```
Apply at each iOS site that surfaces the command field/tab.

- [ ] **Step 3: Gate Raymond on iOS.** Where `aiAgentEnabled` (`@AppStorage("raymol.experimental.aiAgent")`) gates the Raymond tab/entry and the `raymondOverlay`, additionally require `!RAYMOL_IOS_APPSTORE_RESTRICTED`; in `SettingsSheet` (ObjectPanel.swift) hide the "AI Assistant (Raymond)" experimental toggle under the flag on iOS.

- [ ] **Step 4: Verify both states build.** Default (flag off) — command line + Raymond present; flag on — both gone, app still builds + runs GUI-only.
```bash
cd swiftui && xcodegen generate
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | tail -3
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' OTHER_SWIFT_FLAGS='-D RAYMOL_IOS_APPSTORE_RESTRICTED' build 2>&1 | tail -3
```
Expected: both `** BUILD SUCCEEDED **`. Install the restricted build on the sim and confirm no command field / no Raymond entry.

- [ ] **Step 5: Commit.**
```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Panels/ObjectPanel.swift swiftui/project.yml
git commit -m "feat(appstore-ios): RAYMOL_IOS_APPSTORE_RESTRICTED fallback hides command line + Raymond on iOS"
```

---

### Task 14: iOS archive + upload + submit  **[agent archives; you do portal]**

**Files:** none new (reuses `archive_appstore.sh`)

- [ ] **Step 1: [agent] Archive the iOS slice** (default build — surfaces present, attempting to pass):
```bash
swiftui/archive_appstore.sh iOS 2>&1 | tail -8
```
Expected: `.ipa`/archive under `swiftui/build_export/iOS/`.

- [ ] **Step 2: [you — portal] Add the iOS platform** to the existing App Store Connect record; reuse metadata; add iPhone 6.9" + iPad 13" screenshots from Task 9.
- [ ] **Step 3: [you — portal] Upload** the iOS build (Organizer → Distribute, or Transporter); TestFlight-install on your iPhone + iPad; re-run the feature sweep on-device (incl. command line + Raymond with the demo key).
- [ ] **Step 4: [you — portal] Submit for review** with `docs/appstore/review-notes.md` attached.
- [ ] **Step 5: [contingency] If rejected on 2.5.2:** flip `RAYMOL_IOS_APPSTORE_RESTRICTED` on (uncomment the Release-iOS variant in `project.yml`), re-archive (Task 14 Step 1), re-upload, and resubmit GUI-only with a note that the scripting/AI surfaces were removed for the iOS release.

---

## Self-Review

**Spec coverage:** §1 Identity → Tasks 1–2; §2 Sandbox/entitlements → Tasks 2–5; §3 Privacy → Tasks 6–7; §4 iOS 2.5.2 → Task 13 (+ review notes Task 10); §5 Assets/metadata → Tasks 8–10, 12; §6 Build/submit/test → Tasks 11–12, 14. All sections covered.

**Placeholder scan:** No "TBD/TODO." Two intentional audit-driven open sets (required-reason APIs in Task 6, subprocess hits in Task 4) are explicitly "declare/handle the minimal true set found by this grep," with the exact grep given — not placeholders.

**Type/name consistency:** `io.raymol.RayMol`, `RayMol.app`, `RAYMOL_IOS_APPSTORE_RESTRICTED`, `archive_appstore.sh`, `RayMol.entitlements`, `PrivacyInfo.xcprivacy`, team `VT99UQUQ89` used consistently across tasks.

**Note on TDD:** this is a packaging/submission plan, so most "tests" are build/sign/plist verification commands and a runtime sandbox-denial audit rather than unit tests — appropriate for the domain. The one behavioral code change with a clear pass/fail (Task 13 flag) is verified by building both flag states.
