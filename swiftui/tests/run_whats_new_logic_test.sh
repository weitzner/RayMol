#!/bin/bash
# Compile the pure What's New logic together with its unit test and run it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/wn_test"
swiftc "$DIR/PyMOLViewer/Shared/WhatsNewLogic.swift" \
       "$DIR/tests/whats_new_logic_test.swift" \
       -o "$OUT"
"$OUT"
