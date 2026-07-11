#!/bin/bash
# setup_ios_deps.sh — populate deps_ios/ end-to-end: embedded Python, cross-
# compiled freetype/libpng, numpy, and Biopython, in dependency order. Mirrors
# the one-command feel of fetch_macos_python.sh for the iOS side, which
# unavoidably has more moving pieces (a cross-compiled dependency set, not a
# single vendored Python). Re-run to refresh everything; each step is
# individually idempotent.
#
# MacPorts (or any non-Homebrew prefix): export PYMOL_EXTERNAL_PREFIX=/opt/local
# first — see swiftui/README.md's "Package-manager portability" section.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1/4: fetch_ios_python.sh ==="
"$ROOT/scripts/fetch_ios_python.sh"

echo ""
echo "=== 2/4: build_ios_deps.sh (freetype + libpng cross-compile) ==="
"$ROOT/scripts/build_ios_deps.sh"

echo ""
echo "=== 3/4: build_numpy_ios.sh ==="
"$ROOT/scripts/build_numpy_ios.sh"

echo ""
echo "=== 4/4: bundle_biopython.sh ==="
"$ROOT/scripts/bundle_biopython.sh"

echo ""
echo "=== deps_ios/ ready — build the core next: swiftui/build_ios.sh [device] ==="
