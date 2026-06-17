# RayMol — App Store Submission (macOS + iOS) Design

**Date:** 2026-06-17
**Branch:** `swiftui-cross-platform` / `master` (fork `javierbq/RayMol`)
**Status:** Approved design, ready for implementation plan

## Goal

Ship **RayMol** — the native SwiftUI + Metal fork of PyMOL with embedded CPython 3.13 — to **both** the Mac App Store and the iOS App Store as a **single, free, universal app**. This supersedes the original "Phase D" scope (ad-hoc sign + standalone local launch).

## Strategy

**Phased, macOS-first (Approach A).** The identity / sandbox / privacy / signing groundwork is shared by the one universal target, so it's done once. Then:

1. **Shared groundwork** — identity, App Sandbox + Hardened Runtime + entitlements, privacy manifest, signing.
2. **macOS submission first** — lenient review validates the whole sandbox/signing/metadata pipeline against the easier reviewer.
3. **iOS submission** — armed with the macOS learnings and the guideline-2.5.2 fallback ready.

Rationale: same total work, but the sandbox/signing/trademark posture is proven on the forgiving store before betting on the risky one; the iOS 2.5.2 attempt is the last step rather than the blocker for everything.

## Fixed decisions

| Decision | Value |
|---|---|
| Stores | Mac App Store **and** iOS App Store |
| App model | One universal app (same bundle ID both platforms, universal purchase) |
| Bundle ID | `io.raymol.RayMol` |
| On-disk product name | Rename `PyMOLViewer` → **`RayMol`** (ship `RayMol.app`) |
| App category | Education |
| Pricing | Free, no IAP |
| Dev team | `VT99UQUQ89` (paid account) |
| iOS 2.5.2 surfaces | Keep command line + Raymond; attempt to pass, with a one-flip fallback + review notes |
| Web | Privacy policy + support at **raymol.io** (policy text drafted here, user publishes) |
| Display name | "RayMol" (already set via CFBundleDisplayName / CFBundleName) |

## Non-goals (v1)

- CI-based archive/upload automation (can revive later with an ASC API key).
- In-app purchases / paid tier.
- Reworking Raymond to avoid code execution (we attempt to pass as-is on iOS; fallback hides it).

---

## Section 1 — Identity & project configuration

**`project.yml` changes:**
- `bundleIdPrefix: org.pymol` → `io.raymol`
- `PRODUCT_BUNDLE_IDENTIFIER: org.pymol.viewer` → `io.raymol.RayMol`
- `PRODUCT_NAME: PyMOLViewer` → `RayMol` (ship `RayMol.app`)
- Release config: `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = VT99UQUQ89`, `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = YES`, `CODE_SIGN_ENTITLEMENTS = PyMOLViewer/RayMol.entitlements`
- Keep `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.education`
- `ITSAppUsesNonExemptEncryption = NO` in the generated Info.plist (see Section 3)

**Product-name rename blast radius (update all):**
- `swiftui/build_macos.sh`, `swiftui/build_ios.sh`, `swiftui/build.sh` — any `PyMOLViewer.app` path references.
- The PID-capture harness expectations (`/tmp/repcap.sh`, `build_xcode`/`build_macos_swiftui` output paths) and memory notes referencing `PyMOLViewer.app`.
- `simctl` launch calls: `org.pymol.viewer` → `io.raymol.RayMol` (test scripts + harness).
- The xcframework / Python embed phase paths that key off the product name.
- The document-type registration build phase (re-registers UTIs under the new bundle ID — no code change, just re-runs).

**Preserved (no change):**
- `UserDefaults` keys (`raymol.*`, `mouseLegendCollapsed`, `exportRayTraced`, `raymol.experimental.aiAgent`) — independent of bundle ID.
- Keychain group changes with the bundle ID; App Store installs are fresh, so no migration needed.

**Verification:** target builds for both platforms; `RayMol.app` bundle has `CFBundleIdentifier = io.raymol.RayMol`, `CFBundleName`/`CFBundleDisplayName = RayMol`; `simctl install` + launch under the new ID works.

---

## Section 2 — App Sandbox, Hardened Runtime & entitlements

Both stores require App Sandbox; the App Store requires Hardened Runtime. iOS is already sandboxed; the new constraints land mainly on macOS and are validated on both.

**`RayMol.entitlements` (shared, minor per-platform tweaks):**
- `com.apple.security.app-sandbox` = `true`
- `com.apple.security.network.client` = `true` — PDB fetch (RCSB) + Raymond (Anthropic / Vertex)
- `com.apple.security.files.user-selected.read-write` = `true` — open/save/export via `NSOpenPanel` / `NSSavePanel` / iOS document picker (grants security-scoped access to user-picked paths only)
- Keychain access group for the stored LLM API key under `io.raymol.RayMol`

**Deliberately excluded** (avoid red-flag entitlements):
- `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory` — CPython 3.13's JIT is off by default, so they're unnecessary.
- `com.apple.security.cs.disable-library-validation` — avoided by signing **every** embedded binary (BeeWare `Python.framework`, all bundled `.so`/`.dylib` native modules) with the distribution cert in the embed/sign build phase. If a same-team re-sign of all embedded code proves infeasible, falling back to `disable-library-validation` is the documented contingency (allowed by the App Store but flagged).

**Sandbox behavior changes (accepted):**
- **File access becomes scoped** to the app container + user-picked paths. Consequences:
  - GUI Open/Save/Export (panels) — unaffected (security-scoped).
  - Typed/scripted arbitrary paths on the sandboxed macOS build (`load /abs/path`, a script writing `~/Desktop` or `/tmp`) — **denied** unless routed through the picker. Accepted limitation; consistent with review expectations.
  - `fetch` download path — default to the app container (Application Support), not cwd.
  - Temp files (`tempfile.gettempdir()`, e.g. the theme-preview `pymol_seq.json`, hi-res PNG temp) — already land in the container. OK.
- **No external process spawning** — audit bundled `pymol`/`chempy` modules on reachable feature paths for `subprocess`/`os.system`/`os.popen`; reroute or gate any found.

**Work:** create the entitlements file; enable sandbox + hardened runtime; extend the embed/sign phase to sign all bundled native code; reroute `fetch`/any container-relative paths; audit for subprocess use.

**Verification:** run the **signed, sandboxed** build; Console filtered on `sandbox`/`deny` while exercising every feature; iterate entitlements + path rerouting until the log is clean. (This audit-and-fix loop is the bulk of the real effort and the main risk.)

---

## Section 3 — Privacy & compliance

- **Privacy manifest `PrivacyInfo.xcprivacy`** (bundled, both platforms):
  - Declare required-reason APIs actually used: `UserDefaults` (reason `CA92.1`), and file-timestamp / disk-space / system-boot-time reason codes **only if** the app or embedded Python reach them (audit; declare the minimal true set).
  - `NSPrivacyTracking = false`; no tracking domains; no third-party tracking SDKs (LLM + RCSB are direct HTTPS calls, no embedded SDK).
- **App Privacy nutrition labels** (App Store Connect): disclose **User Content** (prompts + molecule context sent to the LLM when Raymond is used) → **App Functionality**, **not linked to identity**, **not used for tracking**. PDB fetch (public IDs) is not user-data collection. Themes/settings/API key are local only (Keychain). Not eligible for "Data Not Collected" because the optional AI path exists.
- **Encryption:** `ITSAppUsesNonExemptEncryption = NO` (standard HTTPS/TLS only) → export-compliance exempt.
- **ATS / permissions:** all endpoints HTTPS (no ATS exceptions); no camera/mic/location/contacts; files via picker → **no permission usage-strings required**.
- **raymol.io pages:** draft a privacy policy (AI data flow + provider, PDB fetch, no analytics, local/Keychain storage, contact) and a short support page. User publishes; URLs go in App Store Connect (privacy policy → `raymol.io/privacy`, support + marketing → `raymol.io`).

**Verification:** Xcode privacy-manifest report shows only declared reasons; nutrition labels match the manifest; policy URLs resolve.

---

## Section 4 — iOS guideline-2.5.2 strategy

- **Fallback switch `RAYMOL_IOS_APPSTORE_RESTRICTED`** (Swift compilation condition; default **off** = ship the surfaces). When on, the **iOS** target compiles out:
  - the command-line input field (CommandPanel input), and
  - the Raymond UI entry (already gated by `raymol.experimental.aiAgent`, off by default; restricted mode also hides the toggle + entry).
  Flipping it on a rejection = one-line change + rebuild + resubmit, no rearchitecture. macOS is unaffected (keeps both surfaces always).
- **Review notes** (submitted with the iOS build):
  - RayMol is established-style scientific software; the command line is PyMOL's documented scripting interface driving the **bundled** engine — it does not download or install new app features.
  - Raymond is **optional, off by default**, requires the **user's own LLM API key**; include a **demo key + step-by-step** so the reviewer can test, and state the app is fully functional without it (addresses 3.1.1 / 2.1).
  - Honest framing: Raymond converts natural language into the app's own documented commands against the already-loaded structure.

**Verification:** default build ships both surfaces on iOS; setting the flag hides both on iOS only and leaves macOS untouched; review-notes doc prepared with demo key + steps.

---

## Section 5 — Store assets & metadata

- **App name:** "RayMol" (verify uniqueness in App Store Connect; fallback "RayMol – Molecular Viewer"). Subtitle e.g. "Molecular visualization & ray tracing".
- **Icon:** confirm the asset catalog contains every required size for both platforms incl. the **1024×1024 marketing icon** (no alpha, no rounded corners). Source = existing RayMol icon (sunset "R" + p-orbitals).
- **Screenshots:** generate candidates with the existing capture harness — iOS/iPad via `simctl io screenshot`, macOS via the PID-exact capture — for each required device class (macOS, iPhone 6.9", iPad 13"), showing themed cartoons + ray-traced surfaces. User approves/swaps.
- **Listing text:** draft description, keywords, promotional text, "what's new." Support + marketing URL → `raymol.io`; privacy policy → `raymol.io/privacy`.
- **Age rating:** 4+ (no objectionable content; Raymond is not a web browser).
- **Copyright:** credits PyMOL / Schrödinger per the BSD-like license; RayMol stated as an independent fork.

**Verification:** App Store Connect record passes metadata validation (all required assets present, URLs resolve, rating completed).

---

## Section 6 — Build, submission pipeline & testing

- **Archive & export:** `xcodebuild archive` once per platform slice (`generic/platform=macOS`, then `generic/platform=iOS`) of the universal target; export with the **App Store** method + automatic Distribution signing.
- **Notarization:** App Store builds are notarized by Apple during review — not self-notarized (self-notarization is only for outside-store Developer-ID distribution).
- **Upload:** primary path = Xcode Organizer → "Distribute App"; document a headless alternative (App Store Connect API key + `xcrun altool` / Transporter) for later CI.
- **TestFlight first:** push each build to TestFlight; install the **signed, sandboxed** build on Mac + iPhone + iPad; smoke-test there to surface real sandbox denials before review.
- **Verification plan:**
  - **Sandbox audit** — signed sandboxed run, Console filtered on `sandbox`/`deny`, exercise every feature until clean.
  - **Functional regression** — load / fetch / save / PNG + session export / all reps / themes / measurements / timeline + movie / command line / Raymond (demo key).
  - Confirm no prohibited entitlements; review Xcode's privacy-manifest report.
- **Submission order (Phase A):** macOS through review first; on approval, submit iOS with the 2.5.2 notes + fallback ready.

---

## Risks

1. **Embedded Python under sandbox (highest-effort).** Same-team signing of all embedded native code to avoid `disable-library-validation`; scoped file access; subprocess audit. Mitigation: the Console-denial audit loop on TestFlight before review.
2. **iOS guideline 2.5.2 (highest rejection-risk).** Command line + Raymond run user/LLM-supplied code. Mitigation: review notes + demo key + the one-flip `RAYMOL_IOS_APPSTORE_RESTRICTED` fallback (resubmit GUI-only).
3. **Raymond requiring the user's own API key** (3.1.1 / 2.1). Mitigation: feature is optional/off by default; app fully functional without it; demo key in review notes.
4. **Trademark / fork posture.** "PyMOL" is Schrödinger's mark. Mitigation: store name + branding are "RayMol"; copyright + fork disclaimer credit PyMOL/Schrödinger; BSD-like license permits the fork.

## Success criteria

- macOS: `RayMol.app` (`io.raymol.RayMol`) is sandboxed + hardened-runtime signed, passes a clean Console sandbox audit, runs every feature, and is **approved on the Mac App Store**.
- iOS: the same universal app is **approved on the iOS App Store** (or, on a 2.5.2 rejection, resubmitted GUI-only via the fallback and approved).
- Both: free, universal, with privacy manifest + honest nutrition labels, privacy/support pages live at raymol.io.
