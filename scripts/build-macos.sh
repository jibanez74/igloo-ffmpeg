#!/usr/bin/env bash
# Builds Igloo's ffmpeg and ffprobe for darwin_arm64 natively on an Apple
# Silicon Mac (see ../build.sh) and writes out/darwin_arm64/. common.sh does
# the shared work; this file adds the toolchain and VideoToolbox.
#
# Needs Xcode (or its command line tools), plus from Homebrew: bash (4.4 or
# newer), gnu-tar, xz, autoconf, automake, libtool, pkgconf; and meson and ninja.
set -euo pipefail
(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404 )) || { echo "build-macos.sh needs bash 4.4 or newer (Homebrew's)" >&2; exit 1; }

B=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM=darwin_arm64
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo "build-macos.sh runs on an Apple Silicon Mac" >&2; exit 1; }

# The oldest macOS the binaries run on: the same floor as the Jellyfin build
# Igloo embedded before.
export MACOSX_DEPLOYMENT_TARGET=12.0
# Static archives without member timestamps, so rebuilds stay identical.
export ZERO_AR_DATE=1
export CC=clang CXX=clang++
export TAR=${TAR:-gtar}
export LIBTOOLIZE=${LIBTOOLIZE:-glibtoolize}
CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -fPIC"
LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
source "$B/scripts/common.sh"
export CFLAGS="-I$PREFIX/include $CFLAGS"
export CXXFLAGS=$CFLAGS
export LDFLAGS="-L$PREFIX/lib $LDFLAGS"

build_deps zlib x264 zimg dav1d

# VideoToolbox: the videotoolbox hwaccel, h264_videotoolbox and scale_vt.
# zimg's C++ runtime is the system libc++. Only the system libraries and
# frameworks stay dynamic.
ENCODERS+=(h264_videotoolbox)
FILTERS+=(scale_vt)
build_ffmpeg --cc=clang --cxx=clang++ --enable-videotoolbox

# strip (run by FFmpeg's install of ffmpeg and ffprobe) can leave the linker's
# ad-hoc signature stale, and Apple Silicon refuses to run unsigned code.
# Re-sign ad hoc: no identity, no timestamp, so the result is reproducible.
post_install() {
  local bin
  for bin in "$OUT/ffmpeg" "$OUT/ffprobe"; do
    codesign --force --sign - "$bin"
    codesign --verify --strict "$bin"
  done
}

toolchain_info() {
  sw_vers | tr '\t' ' '
  xcodebuild -version 2> /dev/null | tr '\n' ' ' && echo
  echo "SDK $(xcrun --show-sdk-version)"
  clang --version | head -1
  echo "deployment target $MACOSX_DEPLOYMENT_TARGET"
  echo "meson $(meson --version), ninja $(ninja --version)"
  echo "$("$TAR" --version | head -1); $(autoconf --version | head -1); $(automake --version | head -1); $("$LIBTOOLIZE" --version | head -1)"
}
SOURCE_BUNDLE=0 package
