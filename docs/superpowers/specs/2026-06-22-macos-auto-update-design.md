# RayMol macOS Auto-Update (Sparkle) — Design

**Date:** 2026-06-22
**Status:** Approved (design)
**Scope:** macOS direct-distribution (DMG) build only

## Problem

RayMol for macOS is distributed outside the App Store as a Developer-ID-signed,
notarized, stapled DMG (built by `swiftui/make_dmg.sh`). Once installed, the app
has no way to discover, download, or install a newer version — users must
manually find and re-download the DMG. iOS/iPadOS builds go through the App
Store and auto-update via Apple, so they are out of scope.

This design adds in-app update checking and one-click download + install to the
macOS app using the Sparkle framework, with releases published to GitHub
Releases on the `javierbq/RayMol` repository.

## Decisions (locked)

- **Framework:** Sparkle 2.x (de-facto standard for non-MAS macOS apps).
- **Hosting:** GitHub Releases on `github.com/javierbq/RayMol`.
- **UX:** Auto-check on launch + every 24h; when an update is found, prompt with
  release notes and a one-click "Install & Relaunch". Also a manual
  "Check for Updates…" menu item.
- **Release flow:** Local (no CI). Extend the existing `make_dmg.sh` flow with a
  `publish_release.sh` script; signing keys stay on the developer's machine.
- **Feed URL:** `https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml`
  (`latest/download` always resolves to the newest published release, so the URL
  is stable).
- **Version comparison:** Sparkle compares on `CFBundleVersion`
  (`CURRENT_PROJECT_VERSION`, currently `4`). **Every release MUST bump
  `CURRENT_PROJECT_VERSION`.** `MARKETING_VERSION` is the user-facing string.

## Architecture & data flow

```
RayMol.app (installed)                 GitHub Releases (javierbq/RayMol)
┌───────────────────────────┐         ┌────────────────────────────┐
│ Sparkle SPUStandardUpdater │ ──GET──▶│ appcast.xml (release asset) │
│  ↳ RayMolUpdater.swift     │         │ RayMol-X.Y.Z.dmg            │
│  ↳ "Check for Updates…"    │ ◀─DMG── │ (EdDSA sig in appcast item) │
│     menu item              │         └────────────────────────────┘
└───────────────────────────┘
   on launch + every 24h: fetch appcast → compare CFBundleVersion
   → if newer: prompt (release notes) → download → verify EdDSA + notarization
   → install (replace bundle) → relaunch
```

Updates are doubly protected: Apple Developer ID / notarization **and** Sparkle's
EdDSA signature. Both must validate or the install is refused.

## Components

### App-side

The macOS and iOS apps are a **single multi-platform xcodegen target**
(`PyMOLViewer`, `platform: [macOS, iOS]`, split into `_macOS`/`_iOS`). Sparkle is
macOS-only, so:

- **Dependency:** add Sparkle 2.x to `swiftui/project.yml` under a top-level
  `packages:` block, and add it as a target dependency **filtered to macOS**
  (`platformFilter: macOS`) so the iOS slice never links it.
- **New file** `swiftui/PyMOLViewer/Shared/RayMolUpdater.swift`, entirely wrapped
  in `#if os(macOS)`: a small `ObservableObject` wrapping
  `SPUStandardUpdaterController(startingUpdater: true, …)`.
- **Menu:** in `swiftui/PyMOLViewer/Shared/PyMOLApp.swift`, inside the existing
  `.commands { }`, add (macOS-only, `#if os(macOS)`) a
  `CommandGroup(after: .appInfo)` containing a **"Check for Updates…"** button
  bound to the updater's `checkForUpdates()`.
- **Info.plist keys** (macOS only). Because the Info.plist is generated
  (`GENERATE_INFOPLIST_FILE: YES`) and shared across platforms, set these via the
  existing macOS post-build `plutil` step (alongside the current `CFBundleName`
  brand fix) rather than `INFOPLIST_KEY_*`:
  - `SUFeedURL` = `https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml`
  - `SUPublicEDKey` = the base64 EdDSA public key
  - `SUEnableAutomaticChecks` = `YES`
  - `SUScheduledCheckInterval` = `86400`

### Signing & entitlements

- The Developer ID build is **not sandboxed** and `make_dmg.sh` already signs
  every nested Mach-O deepest-first with Hardened Runtime + timestamp. Sparkle's
  embedded `Autoupdate`, `Updater.app`, and XPC services live inside the bundle
  and are therefore signed correctly by the **existing** loop — no change to the
  signing logic is required.
- If the direct build is ever sandboxed, Sparkle requires specific XPC
  entitlements. Out of scope now.

### Update signing (EdDSA)

Sparkle requires each update to be signed with an EdDSA key, separate from the
Apple Developer ID:

- **One-time:** run Sparkle's `generate_keys`. The private key is stored in the
  login keychain; the public key is placed in `SUPublicEDKey`. The private key
  never leaves the machine and is never committed.
- **Per release:** `sign_update RayMol-X.Y.Z.dmg` emits the
  `sparkle:edSignature` and `length` attributes for the appcast item.

## Build / publish flow (local)

1. `swiftui/make_dmg.sh` — unchanged: builds, Developer-ID-signs, notarizes,
   staples, produces `RayMol-X.Y.Z.dmg`.
2. **New `swiftui/publish_release.sh`** — runs after `make_dmg.sh`:
   1. Reads `VERSION` (marketing) and `CURRENT_PROJECT_VERSION` (build number).
   2. Runs Sparkle `sign_update` on the notarized DMG.
   3. Regenerates/updates `appcast.xml`, appending a new `<item>`:
      `sparkle:version` (CFBundleVersion), `sparkle:shortVersionString`
      (marketing), `enclosure` URL → the DMG's GitHub download URL,
      `sparkle:edSignature` + `length`, `sparkle:minimumSystemVersion` = `13.0`,
      and a `<sparkle:releaseNotesLink>` (or `<description>`) → the GitHub
      release page.
   4. Publishes via
      `gh release create vX.Y.Z RayMol-X.Y.Z.dmg appcast.xml --notes …`,
      uploading **both** the DMG and `appcast.xml` as release assets so
      `latest/download/appcast.xml` resolves to the newest version.
3. `appcast.xml` is also committed to the repo as the source-of-truth history.

Release notes are authored once as the GitHub release body and surfaced in
Sparkle's prompt via the release-notes link.

## Error handling & edge cases

- **Feed unreachable / network error:** scheduled checks fail silently; manual
  "Check for Updates…" surfaces an error dialog.
- **Signature mismatch (EdDSA or notarization):** Sparkle refuses to install and
  reports failure; the running app is never replaced.
- **Downgrade / equal version:** no prompt (build-number comparison).
- **First run:** Sparkle's standard "check automatically?" consent prompt; with
  `SUEnableAutomaticChecks = YES` set, automatic checks are pre-enabled.
- **iOS slice:** zero impact — all Sparkle code is `#if os(macOS)` and the
  dependency is platform-filtered.

## Testing / verification

- **End-to-end:** build vX; run `publish_release.sh` for a higher vX+1 against a
  scratch tag/repo; point a dev build's `SUFeedURL` at it; confirm
  prompt → download → verify → install → relaunch.
- **Signing:** after `make_dmg.sh`, confirm Sparkle helpers pass
  `codesign --verify --deep --strict` and `spctl -a -vvv` on the bundle.
- **Negative:** corrupt the DMG or use a wrong EdDSA signature → install must be
  rejected and the running app left intact.

## Out of scope

iOS/iPadOS updates (App Store), CI automation of releases, Sparkle delta
updates, and multi-channel (beta) feeds. All deferrable.
