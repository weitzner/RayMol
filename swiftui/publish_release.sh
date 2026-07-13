#!/bin/bash
# publish_release.sh — EdDSA-sign the notarized DMG, regenerate appcast.xml,
# publish the DMG + appcast to GitHub Releases on javierbq/RayMol, and bump the
# Homebrew cask tap (javierbq/homebrew-raymol) so `brew` serves the new version.
#
# Run AFTER make_dmg.sh has produced a notarized RayMol-<VERSION>.dmg at the repo
# root. The appcast feed served at
#   https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml
# is what installed RayMol.app polls (SUFeedURL in Info.plist). The Homebrew cask
# bump is the LAST step (it needs the release asset live); it is non-fatal and
# can be skipped with SKIP_CASK=1.
#
# Usage:
#   VERSION=1.1.0 BUILD=5 NOTES_FILE=docs/release-notes/v1.1.0.md \
#     bash swiftui/publish_release.sh
#
# VERSION   = marketing version (CFBundleShortVersionString)
# BUILD     = CFBundleVersion (CURRENT_PROJECT_VERSION) — Sparkle compares on this,
#             so it MUST increase every release.
# NOTES_FILE = Markdown release notes. Embedded into the appcast as
#             <description sparkle:format="markdown"> so Sparkle renders them
#             natively in the update dialog (no GitHub web page), and also used
#             as the GitHub release body. Optional; falls back to a short blurb.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="javierbq/RayMol"
VERSION="${VERSION:?Set VERSION, e.g. 1.1.0}"
BUILD="${BUILD:?Set BUILD (CFBundleVersion), e.g. 5}"
DMG="$ROOT/RayMol-$VERSION.dmg"
APPCAST="$ROOT/appcast.xml"
# RayMol also ships via a Homebrew Cask tap so users can
#   brew install --cask javierbq/raymol/raymol
# The cask pins an exact version + sha256 of the versioned DMG, so it is bumped
# at the end of this script (after the GitHub release exists). SKIP_CASK=1 skips.
CASK_TAP_REPO="${CASK_TAP_REPO:-javierbq/homebrew-raymol}"
SKIP_CASK="${SKIP_CASK:-0}"

[ -f "$DMG" ] || { echo "ERROR: $DMG not found (run make_dmg.sh first)"; exit 1; }

# Sparkle's sign_update ships inside the resolved SPM artifact.
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Sparkle/bin/sign_update' 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "ERROR: sign_update not found; run 'xcodebuild -resolvePackageDependencies' first"; exit 1; }

# --- Preflight (hardening after the 1.2.1 publish got tripped up) -------------
# 1. Keep the Mac awake for the whole run. A sleep/lock cycle mid-publish can
#    evict the keychain credentials sign_update needs and force a fresh, easily-
#    missed authorization prompt (sign_update then hangs). -w $$ ties caffeinate's
#    lifetime to this script, so it stops automatically when we exit.
caffeinate -dims -w "$$" &

# 2. The login keychain must be unlocked — sign_update reads the Sparkle EdDSA
#    key from it. Fail fast with a clear message instead of hanging deep in the
#    run on an unattended keychain prompt.
if ! security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "ERROR: login keychain is locked. Unlock it and re-run, e.g.:"
  echo "  security unlock-keychain \"\$HOME/Library/Keychains/login.keychain-db\""
  exit 1
fi

# 3. Snapshot the release notes NOW, before the long sign/upload. The GitHub
#    release is created at the END of this script; if the working tree changes
#    in between (a branch switch or checkout — which is exactly what broke the
#    1.2.1 create), NOTES_FILE can vanish. Copy it to a stable temp path up front
#    and create the release from that, independent of the live checkout.
NOTES_SNAPSHOT=""
if [ -n "${NOTES_FILE:-}" ]; then
  [ -f "$NOTES_FILE" ] || { echo "ERROR: NOTES_FILE not found: $NOTES_FILE"; exit 1; }
  NOTES_SNAPSHOT="$(mktemp -t raymol-relnotes)"
  cp "$NOTES_FILE" "$NOTES_SNAPSHOT"
  echo "  notes snapshot → $NOTES_SNAPSHOT"
fi
# ------------------------------------------------------------------------------

echo "== EdDSA-sign the DMG =="
# sign_update prints an attribute fragment, e.g.:
#   sparkle:edSignature="…" length="12345"
SIGFRAG="$("$SIGN_UPDATE" "$DMG")"
echo "  $SIGFRAG"

URL="https://github.com/$REPO/releases/download/v$VERSION/RayMol-$VERSION.dmg"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

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
      <description xml:lang="en" sparkle:format="markdown"><![CDATA[
__RELEASE_NOTES_CDATA__
]]></description>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGFRAG />
    </item>
  </channel>
</rss>
XML

# Splice the release notes into the appcast's <description> as Markdown. This is
# done here (not in the heredoc above) on purpose: the notes contain backticks
# and may contain '$', which an unquoted heredoc would mangle. Python inserts the
# bytes verbatim and guards the CDATA section against a literal ']]>'.
python3 - "$APPCAST" "${NOTES_SNAPSHOT:-}" <<'PY'
import sys
appcast_path, notes_path = sys.argv[1], sys.argv[2]
if notes_path:
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read().strip()
else:
    notes = "Bug fixes and improvements. See the in-app release notes for details."
notes = notes.replace("]]>", "]] >")  # CDATA cannot contain the literal ]]>
with open(appcast_path, encoding="utf-8") as f:
    xml = f.read()
with open(appcast_path, "w", encoding="utf-8") as f:
    f.write(xml.replace("__RELEASE_NOTES_CDATA__", notes))
PY
echo "  wrote $APPCAST"

# Stable-named copy of the DMG so the website can link a FIXED url that always
# serves the newest release: https://github.com/$REPO/releases/latest/download/RayMol.dmg
# (the versioned RayMol-$VERSION.dmg name changes every release, so it can't be
# used with the /latest/ redirect). Same notarized+stapled bytes, second name.
STABLE_DMG="$ROOT/RayMol.dmg"
cp "$DMG" "$STABLE_DMG"

echo "== Publish GitHub release v$VERSION =="
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" --clobber
else
  if [ -n "$NOTES_SNAPSHOT" ]; then
    gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" \
      --title "RayMol $VERSION" --notes-file "$NOTES_SNAPSHOT"
  else
    gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" \
      --title "RayMol $VERSION" \
      --notes "${NOTES:-Automatic updates are here. RayMol now checks for new versions and installs them with one click — no more manual DMG downloads. Built on the open-source PyMOL engine.}"
  fi
fi

echo "RELEASE PUBLISHED → https://github.com/$REPO/releases/tag/v$VERSION"

# == Bump the Homebrew cask =====================================================
# Update version + sha256 in the tap's Casks/raymol.rb and push. Runs AFTER the
# GitHub release is live (the cask URL resolves to that release's DMG asset).
# NON-FATAL by design: the release itself already succeeded, so a tap hiccup
# must not fail the run — it just prints a warning and tells you how to recover.
if [ "$SKIP_CASK" = "1" ]; then
  echo "== Skipping Homebrew cask bump (SKIP_CASK=1) =="
else
  echo "== Bump Homebrew cask ($CASK_TAP_REPO) =="
  CASK_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  echo "  version=$VERSION sha256=$CASK_SHA"
  CASK_TMP="$(mktemp -d -t raymol-cask)"
  if gh repo clone "$CASK_TAP_REPO" "$CASK_TMP/tap" -- -q 2>/dev/null; then
    CASK_FILE="$CASK_TMP/tap/Casks/raymol.rb"
    if [ -f "$CASK_FILE" ]; then
      # Rewrite only the version/sha256 lines (anchored to the stanza indent).
      sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK_FILE"
      sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$CASK_SHA\"/" "$CASK_FILE"
      if git -C "$CASK_TMP/tap" diff --quiet -- Casks/raymol.rb; then
        echo "  cask already at $VERSION / $CASK_SHA — nothing to push"
      else
        git -C "$CASK_TMP/tap" add Casks/raymol.rb
        git -C "$CASK_TMP/tap" commit -qm "raymol $VERSION"
        git -C "$CASK_TMP/tap" push -q origin HEAD
        echo "  pushed cask $VERSION → $CASK_TAP_REPO"
      fi
    else
      echo "  WARNING: $CASK_FILE missing in tap; cask NOT bumped."
    fi
  else
    echo "  WARNING: could not clone $CASK_TAP_REPO; cask NOT bumped."
    echo "           Create the tap once, then bump by hand or re-run with"
    echo "           SKIP_CASK unset. Users would otherwise get the old version."
  fi
  rm -rf "$CASK_TMP"
fi

echo "DONE → https://github.com/$REPO/releases/tag/v$VERSION"
