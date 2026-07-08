# Authoring the "What's New" splash

`WhatsNew.json` drives the in-app **What's New** carousel (see
`Shared/WhatsNewModel.swift`, `Shared/WhatsNewModal.swift`,
`Shared/WhatsNewLogic.swift`). It's bundled with the app, so you edit it as part
of cutting a release.

## When cutting a release

1. Bump `MARKETING_VERSION` in `swiftui/project.yml` as usual.
2. Add **one new object** to the top-level array in `WhatsNew.json`, with
   `version` set to the **exact** new `MARKETING_VERSION` (e.g. `"1.6.0"`), and
   one `page` per feature you want to showcase.
3. (Optional) Add hero images — see below.

That's it. On the first launch after the update, users who were on an older
version see every page for the versions they missed (cumulative), oldest→newest.

## Page format

```json
{
  "version": "1.6.0",
  "pages": [
    {
      "title": "Real-time ray tracing",
      "body": "One or two sentences describing the feature.",
      "videoName": "whatsnew-rt",     // optional: a bundled .mp4 (takes precedence)
      "imageName": "whatsnew-rt",     // optional: an image set in Assets.xcassets
      "systemImage": "sparkles"       // fallback SF Symbol if neither resolves
    }
  ]
}
```

- `title`, `body` — required.
- The hero can be a **video OR an image**. Render precedence is:
  `videoName` → `imageName` → `systemImage` → a neutral gradient. A page always
  renders even with none of them.
- `videoName` — optional. A bundled `.mp4` (see below). Plays muted, looping,
  aspect-fill, with no transport controls.
- `imageName` — optional. Name of an image set in `Assets.xcassets`.
- `systemImage` — optional SF Symbol fallback.

## Adding a hero image

Two ways — both resolved by `imageName`:

- **Simplest (bundled file):** drop a `.png`/`.jpg` into `Resources/` (bundled
  automatically; run `xcodegen generate`) and set `imageName` to its file name
  (extension optional). Same "just drop a file in Resources/" model as videos.
- **Asset catalog:** add an **Image Set** to `Assets.xcassets` (a `WhatsNew` group
  keeps them tidy) with `@2x`/`@3x` slots, and set `imageName` to the set's name.
  This is preferred when found; the bundled-file lookup is the fallback.

Wide hero art works best (~16:9). It's shown `scaledToFill` in a ~420pt-wide card,
clipped to the hero height (238pt macOS / 220pt iOS).

## Adding a hero video (mp4)

1. Drop a short `.mp4` into `Resources/` (it's bundled automatically by the
   `PyMOLViewer` source glob in `project.yml` — run `xcodegen generate` so the
   Xcode project picks it up).
2. Set `videoName` to the file name (the `.mp4` extension is optional).
3. Keep it short, silent (audio is muted anyway), and small — it ships inside the
   app. It loops seamlessly, so author it to loop. `~16:9` fills the hero best
   (aspect-fill crops the rest).

## Behavior notes

- The **release that first shipped this feature does not auto-show** to anyone —
  we can't know what version a user last saw, so we set a baseline silently and
  begin auto-showing from the next release. Users can always open it from the
  RayMol menu ("What's New in RayMol") or, on iOS, Settings.
- Version comparison is numeric (`1.10.0` > `1.9.0`).
- Set the env var `PYMOL_SKIP_WHATS_NEW` to suppress the auto-show (used by UI
  and screenshot tests).

## Testing

Pure version logic (fast, no simulator):

```
swiftui/tests/run_whats_new_logic_test.sh
```

Carousel UI (simulator):

```
xcodebuild test -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PyMOLViewerUITests/WhatsNewUITests
```

The UI test uses `PYMOL_AUTOSHEET=whatsnew` to present the splash and
`PYMOL_SKIP_FIRSTBOOT_THEME=1` so the first-boot Theme Studio doesn't contend for
the presentation slot.
