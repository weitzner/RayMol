# RayMol Privacy Policy

_Last updated: June 17, 2026_

RayMol is a molecular visualization app for macOS, iPad, and iPhone. We designed
it to keep your data on your device. This policy explains what leaves the device,
when, and why.

## Summary

- **RayMol collects no personal data and contains no analytics or tracking.**
- Your structures, sessions, themes, and settings stay **on your device**.
- Data leaves your device only when **you** use a network feature:
  - **Fetch from PDB** — sends the PDB ID you request to the public RCSB Protein
    Data Bank to download that structure.
  - **Raymond (the optional AI assistant)** — when, and only when, you enable it
    and send a message, your prompt and the relevant context about the currently
    loaded structure are sent to the AI provider **you configure** (Anthropic or
    Google Vertex AI) to generate a response.

## The AI assistant (Raymond)

Raymond is **off by default** and entirely optional. RayMol is fully functional
without it.

- Raymond requires **your own API key** for a supported provider. The key is
  stored locally in the **Apple Keychain** on your device and is sent only to
  that provider to authenticate your requests.
- When you send a message to Raymond, your message text and a description of the
  current molecular scene are transmitted to your chosen provider so it can
  answer. That data is handled under **that provider's** privacy policy
  (Anthropic or Google), not by RayMol.
- RayMol does not store your conversations off-device and does not use them for
  any purpose other than answering your request in the moment.

## Fetching structures

When you use "Fetch from PDB," RayMol requests the structure by its public
identifier from RCSB (rcsb.org). No personal information is included in that
request.

## Data we do not collect

We do not collect or transmit identifiers, usage analytics, advertising data,
location, contacts, or any personal information. There are no third-party
tracking SDKs in the app.

## Local storage

Themes, app settings, and the Raymond API key (Keychain) are stored only on your
device and are removed if you delete the app.

## Children

RayMol is rated 4+ and contains no objectionable content. It does not knowingly
collect any information from anyone, including children.

## Changes

If this policy changes, we will update the date above and post the revised policy
at this URL.

## Contact

Questions about this policy: **privacy@raymol.io**

---

RayMol is an independent application built on the open-source
[PyMOL](https://pymol.org) project (© Schrödinger, LLC), distributed under a
BSD-like license. RayMol is not affiliated with or endorsed by Schrödinger.
