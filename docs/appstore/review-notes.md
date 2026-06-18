# RayMol — App Review Notes

These notes accompany the App Store submission (App Store Connect → App Review
Information → Notes), and a demo key for the optional AI feature.

## What RayMol is

RayMol is a scientific molecular-visualization app built on the open-source
**PyMOL** engine (BSD-like license; RayMol is an independent fork, not affiliated
with Schrödinger). It renders 3D molecular structures (proteins, etc.) with a
native Metal renderer. All rendering and computation happen **on device** with a
bundled engine; nothing is downloaded and executed.

## Command line (guideline 2.5.2)

RayMol includes PyMOL's **documented command interface** — the standard way
scientists drive PyMOL (e.g. `show cartoon`, `color blue`, `orient`). This
controls the **bundled** visualization engine that ships inside the app; it does
**not** download, install, or run new executable code or change the app's
features. It is the established, expected interface for this category of
scientific software and is core to the app's stated purpose.

## Optional AI assistant ("Raymond")

- Raymond is **off by default** and entirely optional — the app is fully
  functional without it. It can be enabled in **Settings → Experimental**.
- Raymond translates natural-language requests into the app's **own documented
  commands** to manipulate the **already-loaded** structure. It does not fetch or
  execute arbitrary new app functionality.
- It requires the **user's own API key** for a supported provider (Anthropic or
  Google Vertex AI), stored in the Keychain. The app does not bundle keys.

### To test Raymond (reviewer steps)

1. Launch RayMol → **Open File** (or **Fetch from PDB**, e.g. enter `1ubq`).
2. Go to **Settings → Experimental** and turn on **AI Assistant (Raymond)**.
3. Open the **Raymond** panel/tab → **Settings/Account** within it → paste the
   demo API key below → Save.
4. Type a request such as: _"color the protein by chain and show it as a
   surface."_ Raymond will issue the corresponding view commands.

**Demo API key:** `<INSERT DEMO KEY BEFORE SUBMITTING>`
_(Provide a temporary, rate-limited key for a provider you control; rotate it
after review. Do not commit the key to source control.)_

## Privacy

No personal data is collected; no analytics/tracking. Network use is limited to
(a) fetching public structures from RCSB PDB by ID, and (b) sending the user's
prompt + current-scene context to the user-configured AI provider when Raymond is
used. See https://raymol.io/privacy.

## Notes

- No account or login is required to use RayMol.
- Standard HTTPS only; export-compliance exempt
  (`ITSAppUsesNonExemptEncryption = NO`).
