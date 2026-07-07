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
    imageName:   String?   // asset-catalog name; optional
    systemImage: String?   // SF Symbol fallback when imageName is nil/missing
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
- `✕` / "Skip" dismisses anytime (also marks seen).
- Presented as a centered `.sheet` on macOS (fixed ~380–420pt wide) and a `.sheet`
  on iOS. Attached **once** via a `WhatsNewPresenter` view modifier wrapped around
  `ContentView.body`, so both `macOSLayout` and `iPadOSLayout` are covered.

## Entry points

- **macOS:** `Button("What's New in RayMol")` in `PyMOLApp.macCommands`, in the
  app-menu group after `.appInfo` (beside About / Check for Updates). Posts
  `.raymolShowWhatsNew`.
- **iOS/iPadOS:** a prominent "What's New in RayMol" row at the top of
  `SettingsSheet`. It dismisses the settings sheet, then posts
  `.raymolShowWhatsNew` (avoids nested-sheet presentation issues).
- The `WhatsNewPresenter` listens for `.raymolShowWhatsNew` and presents the
  modal on all current content (manual open ignores `lastSeenVersion`).

## Files

New:
- `Shared/WhatsNewModel.swift` — data model, catalog loader, version logic.
- `Shared/WhatsNewModal.swift` — the carousel view + `WhatsNewPresenter` modifier.
- `Resources/WhatsNew.json` — seed content (current release).
- `Assets.xcassets/WhatsNew/…` — seed images (optional; systemImage fallbacks OK).

Edited:
- `Shared/ContentView.swift` — `.raymolShowWhatsNew` notification name; wrap
  `body` with the presenter; own the `WhatsNewModel` `@StateObject`.
- `Shared/PyMOLApp.swift` — app-menu item posting `.raymolShowWhatsNew`.
- `Panels/ObjectPanel.swift` — "What's New" row in `SettingsSheet`.

## Testing

- **Unit (pure logic):** standalone `swift` script exercising
  `WhatsNewModel.pagesToShow(current:lastSeen:releases:)` and the semver compare —
  cumulative across skipped versions, empty on fresh install, empty on downgrade,
  correct ordering. (Same pattern as the CartoonLOD math test.)
- **Functional:** build both targets; on macOS (via `raymol-mac-vm`) and the iOS
  simulator: bump version / clear `whatsNewLastSeenVersion` to confirm auto-show;
  confirm manual open from menu + settings; confirm fresh-install skip; confirm
  cumulative content across a skipped version.

## Out of scope (YAGNI)

- Remote/fetched content (bundled only).
- A user "don't show automatically" preference (auto-show is already once-per-
  version; can be added later if wanted).
- Per-page rich media beyond a single image (video, GIF).
