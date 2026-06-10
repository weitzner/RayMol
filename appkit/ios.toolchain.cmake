# ios.toolchain.cmake — CMake toolchain for cross-compiling to iOS / iOS Simulator
#
# Usage:
#   cmake ../appkit -DCMAKE_TOOLCHAIN_FILE=../appkit/ios.toolchain.cmake \
#         -DIOS_PLATFORM=SIMULATOR64   # or OS for device
#
# Platforms:
#   OS            — arm64 device (iphoneos)
#   SIMULATOR64   — arm64 simulator (iphonesimulator)

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES arm64)

if(NOT IOS_PLATFORM)
    set(IOS_PLATFORM "SIMULATOR64")
endif()

if(IOS_PLATFORM STREQUAL "OS")
    set(CMAKE_OSX_SYSROOT iphoneos)
elseif(IOS_PLATFORM STREQUAL "SIMULATOR64")
    set(CMAKE_OSX_SYSROOT iphonesimulator)
else()
    message(FATAL_ERROR "Unknown IOS_PLATFORM: ${IOS_PLATFORM}. Use OS or SIMULATOR64.")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "Minimum iOS version")

# Skip try_compile checks that fail during cross-compilation
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
