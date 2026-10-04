# Build dependencies for the macOS app (swiftui/), beyond Xcode itself.
# Install or update with:  brew bundle --file=Brewfile
#
# Compilers, xcodebuild and the host python3 come from Xcode / its Command
# Line Tools. These are what Apple doesn't provide. They come from Homebrew
# rather than conda-forge because the app links glm/libpng/freetype/libomp
# statically, and conda-forge doesn't ship static libraries.

# build tools
brew "cmake"      # configures the C++ core (swiftui/build_macos.sh)
brew "xcodegen"   # generates the Xcode project from swiftui/project.yml

# libraries linked into libpymol_core.a / the app
brew "glm"
brew "libpng"
brew "freetype"
brew "libomp"
