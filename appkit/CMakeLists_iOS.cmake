# CMakeLists_iOS.cmake — Build pymol_core static library for iOS
#
# This is a stripped-down version of CMakeLists.txt that:
#   - Targets iOS (no OpenGL, no GLEW, no GLUT)
#   - Only builds the pymol_core static library
#   - Uses header-only references to dependencies (freetype, libpng, Python)
#     since the actual linking happens in the Xcode project
#
# Usage:
#   mkdir build_ios && cd build_ios
#   cmake ../appkit -DCMAKE_TOOLCHAIN_FILE=../appkit/ios.toolchain.cmake \
#         -DIOS_PLATFORM=SIMULATOR64 \
#         -C ../appkit/CMakeLists_iOS.cmake
#
# Or directly:
#   cd build_ios && cmake ../appkit -DPYMOL_IOS=ON \
#         -DCMAKE_TOOLCHAIN_FILE=../appkit/ios.toolchain.cmake

# This file is loaded as an initial-cache script (-C) to set iOS defaults
set(PYMOL_IOS ON CACHE BOOL "Building for iOS")
set(PYMOL_LIBXML OFF CACHE BOOL "Disable libxml2 for iOS")
set(PYMOL_VMD_PLUGINS OFF CACHE BOOL "Disable VMD plugins for iOS")
set(PYMOL_MSGPACKC OFF CACHE BOOL "Disable msgpack-c for iOS")
