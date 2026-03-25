#!/bin/bash
# build.sh — Build the SwiftUI PyMOL viewer for macOS
#
# Prerequisites:
#   1. Build libpymol_core.a first:
#      cd build_appkit && cmake ../appkit && cmake --build . --target pymol_core -j$(sysctl -n hw.ncpu)
#
#   2. Then run this script:
#      cd swiftui && ./build.sh

set -euo pipefail

PYMOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PYMOL_ROOT}/build_appkit"
SWIFTUI_DIR="${PYMOL_ROOT}/swiftui"
STATIC_LIB="${BUILD_DIR}/libpymol_core.a"

# Verify static lib exists
if [ ! -f "$STATIC_LIB" ]; then
    echo "Error: libpymol_core.a not found. Build it first:"
    echo "  cd ${BUILD_DIR} && cmake ../appkit && cmake --build . --target pymol_core -j\$(sysctl -n hw.ncpu)"
    exit 1
fi

# Detect Homebrew
BREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
PYTHON_VERSION="3.14"
PYTHON_PREFIX="${BREW_PREFIX}/opt/python@${PYTHON_VERSION}"
PYTHON_FRAMEWORK="${PYTHON_PREFIX}/Frameworks/Python.framework/Versions/${PYTHON_VERSION}"

echo "=== Building SwiftUI PyMOL Viewer ==="
echo "  PYMOL_ROOT: ${PYMOL_ROOT}"
echo "  Static lib: ${STATIC_LIB}"
echo "  Python:     ${PYTHON_FRAMEWORK}"

# Generate Xcode project
cd "${SWIFTUI_DIR}"
xcodegen generate

echo "=== Xcode project generated ==="
echo ""
echo "To build from Xcode:"
echo "  open ${SWIFTUI_DIR}/PyMOLViewer.xcodeproj"
echo ""
echo "Configure in Xcode Build Settings:"
echo "  - LIBRARY_SEARCH_PATHS: ${BUILD_DIR} ${BREW_PREFIX}/lib"
echo "  - OTHER_LDFLAGS: -lpymol_core -lfreetype -lpng -lglew -lxml2"
echo "  - FRAMEWORK_SEARCH_PATHS: ${PYTHON_FRAMEWORK}/.."
echo "  - Add Python.framework to Link Binary With Libraries"
echo ""
echo "Or build from command line (once Xcode.app is installed):"
echo "  xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer -configuration Debug build"
