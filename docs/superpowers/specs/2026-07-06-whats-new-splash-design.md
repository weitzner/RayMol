# What's New splash modal — design

**Date:** 2026-07-06
**Status:** approved, implementing
**Platforms:** macOS + iPadOS/iOS

## Goal

Give RayMol an in-app "What's New" splash that showcases features added in a
release, including images. It appears automatically the first time the app runs
after a version bump, and can be reopened manually anytime. Content is authored
per release and bundled with the app.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Platforms | macOS **and** iPadOS/iOS (one shared component) |
| Trigger | Auto-show once on first launch after the version changes **plus** a manual entry point |
| Content source | **Bundled** in the app (JSON + images in the asset catalog) |
| Layout | **Paginated carousel** — one feature per page, hero image + title + body, Back/Next + dots |
| Skipped versions | **Cumulative** — show pages for every release newer than the last one seen |
| Manual entry | macOS app menu (next to About / Check for Updates); iOS Settings sheet |

## Content model (bundled)

`Resources/WhatsNew.json` decoded into:

```
WhatsNewRelease {
    version: String        // e.g. "1.6.0"
    pages:   [WhatsNewPage]
}
WhatsNewPage {
    title:       String
    body:        String
    videoName:   String?   // bundled .mp4 name; optional; takes precedence
    imageName:   String?   // asset-catalog name; optional
    systemImage: String?   // SF Symbol fallback when neither video nor image resolves
}
```

- Images live in `Assets.xcassets` under a `WhatsNew` group, referenced by
  `imageName`, cross-platform (macOS + iOS slots), `@1x/@2x/@3x`.
- `imageName` is optional. Render precedence: bundled image → `systemImage` →
  neutral gradient placeholder. A page never fails to render.
- Authoring a release = append one `{version, pages}` entry and drop the images
  in the catalog. This becomes a step in the release checklist (ties into the
  `cut-macos-release` flow).

## Behavior / version logic

`WhatsNewModel` (an `ObservableObject`):

- Reads the current app version from `CFBundleShortVersionString`.
- Persists `@AppStorage("whatsNewLastSeenVersion")`.
- `pagesToShow` = pages of every release whose `version` compares **greater than**
  `lastSeenVersion`, flattened oldest→newest.
- Version comparison is a numeric, component-wise semver compare (`1.6.0` >
  `1.5.2`), padding missing components with `0`. This is **pure and unit-tested**.

Presentation rules:

- **Auto-show:** once per launch, after the UI is up, if `pagesToShow` is
  non-empty → present. On dismiss / "Get Started", set
  `lastSeenVersion = currentVersion`.
- **First run / pre-existing installs:** if `lastSeenVersion` is empty (fresh
  install, OR an existing install that predates this feature), set it to the
  current version and **do not** auto-show. Consequence: the release that first
  ships this feature does not auto-show to anyone (we can't know what they last
  saw); auto-show begins working from the next release. The manual entry point
  always shows the current content regardless.
- **Downgrade / malformed JSON / nothing newer:** nothing auto-shows. Manual open
  shows a graceful "You're up to date" state.
- **Test/headless suppression:** `PYMOL_SKIP_WHATS_NEW` env var suppresses
  auto-show entirely (mirrors `PYMOL_SKIP_GESTURE_HELP`), so UI/screenshot tests
  are unaffected.

## UI

A single shared `WhatsNewModal` view:

- Index-based pager with **Back / Next** buttons and **tappable dots** — works
  identically on macOS and iOS (avoids `TabView`'s iOS-only `.page` style). Swipe
  gesture added on iOS.
- Each page: hero image area on top, centered title + body beneath.
- Last page's primary button reads **Get Started** and dismisses (marks seen).
- `✕` dismisses anytime (also marks seen).
- Presented as a centered `.sheet` on macOS (fixed ~420pt wide) and a `.sheet` on
  iOS using **standard** detents (`[.medium, .large]`). The `.sheet` + the
  auto-show `onAppear` + the `.raymolShowWhatsNew` `onReceive` are attached
  **once**, inlined directly on `ContentView.body` (bound to the `whatsNew`
  `@StateObject`), so both `macOSLayout` and `iPadOSLayout` are covered.
- Implementation notes (learned while getting the XCUITest green): (a) a custom
  `.height()` detent is not reliably traversable by XCUITest on newer iOS — use
  standard detents; (b) do NOT put an `.accessibilityIdentifier` on the modal's
  container view — SwiftUI propagates it to every descendant and shadows the
  per-button ids (`whatsNewPrimary` / `whatsNewClose`) the tests rely on.

## Entry points

- **macOS:** `Button("What's New in RayMol")` in `PyMOLApp.macCommands`, in the
  app-menu group after `.appInfo` (beside About / Check for Updates). Posts
  `.raymolShowWhatsNew`.
- **iOS/iPadOS:** a prominent "What's New in RayMol" row at the top of
  `SettingsSheet`. It dismisses the settings sheet, then posts
  `.raymolShowWhatsNew` (avoids nested-sheet presentation issues).
- `ContentView.body` observes `.raymolShowWhatsNew` and presents the modal on the
  current content (manual open ignores `lastSeenVersion`).

## Files

New:
- `Shared/WhatsNewLogic.swift` — pure, Foundation-only data model + version logic.
- `Shared/WhatsNewModel.swift` — `ObservableObject` controller (presentation
  state, last-seen persistence, bundled-catalog loader).
- `Shared/WhatsNewModal.swift` — the carousel view.
- `Resources/WhatsNew.json` — seed content (current release).
- `Resources/WhatsNew.README.md` — authoring guide for maintainers (not bundled).
- `tests/whats_new_logic_test.swift` + `tests/run_whats_new_logic_test.sh` —
  standalone unit test for the pure logic.
- `PyMOLViewerUITests/WhatsNewUITests.swift` — XCUITest driving the carousel.

Edited:
- `Shared/ContentView.swift` — `.raymolShowWhatsNew` notification name; own the
  `WhatsNewModel` `@StateObject`; inline the auto-show + notification + `.sheet` on
  `body`; `PYMOL_AUTOSHEET=whatsnew` + `PYMOL_SKIP_FIRSTBOOT_THEME` test hooks.
- `Shared/PyMOLApp.swift` — app-menu item posting `.raymolShowWhatsNew`.
- `Panels/ObjectPanel.swift` — "What's New" row in `SettingsSheet`.

## Testing

- **Unit (pure logic):** `swiftui/tests/run_whats_new_logic_test.sh` compiles
  `WhatsNewLogic.swift` with `tests/whats_new_logic_test.swift` and runs 14
  assertions — semver compare, cumulative across skipped versions, empty on fresh
  install / downgrade / nothing-newer, defensive cap at current, manual-page
  fallbacks. **Passing.**
- **UI (XCUITest):** `PyMOLViewerUITests/WhatsNewUITests` launches with
  `PYMOL_AUTOSHEET=whatsnew` and drives the carousel: Next → Next → **Get
  Started** → dismiss, and the ✕ close. **Passing on the iOS simulator.**
- **Builds:** macOS (`PyMOLViewer_macOS`) and iOS (`PyMOLViewer_iOS`) both build
  Debug clean; `WhatsNew.json` is confirmed bundled, `WhatsNew.README.md` excluded.
- **Visual:** confirmed on the iOS simulator via `PYMOL_AUTOSHEET=whatsnew`
  (eyebrow, hero, title/body, dot pager, Next/Get Started, ✕).

## Test hooks added

- `PYMOL_SKIP_WHATS_NEW` — suppress the auto-show entirely.
- `PYMOL_AUTOSHEET=whatsnew` — present the splash on launch (screenshot harness).
- `PYMOL_SKIP_FIRSTBOOT_THEME` — suppress the one-time first-boot Theme Studio so
  it doesn't contend for the presentation slot in a UI test.

## Hero media

The hero resolves **video → image → SF Symbol → gradient** (first that exists).
A bundled `.mp4` (`videoName`) plays muted, looping, aspect-fill, with no
transport controls, via a small AVKit-backed `LoopingVideoView`
(`UIViewRepresentable`/`NSViewRepresentable` over an `AVPlayerLayer`). It
autoplays on appear and pauses/cleans up when its page leaves the carousel (each
page has a distinct `.id`). Hero height: 238pt macOS / 220pt iOS.

## Out of scope (YAGNI)

- Remote/fetched content (bundled only).
- A user "don't show automatically" preference (auto-show is already once-per-
  version; can be added later if wanted).
- Animated GIF / APNG heroes (use an `.mp4` instead — SwiftUI `Image` doesn't
  animate GIFs).
