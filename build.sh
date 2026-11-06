#!/usr/bin/env bash
# Builds Igloo's ffmpeg and ffprobe for the host platform. Output lands in
# out/<platform>/.
#   Linux:  linux_amd64 inside the pinned toolchain container; needs only Docker.
#   macOS:  darwin_arm64 natively on Apple Silicon; see scripts/build-macos.sh
#           for the tools it needs.
#
#   ./build.sh           reuse cached sources and finished dependencies
#   ./build.sh --clean   rebuild everything except the source cache
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case $(uname -s) in
  Darwin) platform=darwin_arm64 ;;
  *) platform=linux_amd64 ;;
esac

if [[ ${1:-} == --clean ]]; then
  rm -rf "$root/work/$platform" "$root/out/$platform"
fi

if [[ $platform == darwin_arm64 ]]; then
  exec bash "$root/scripts/build-macos.sh"
fi

# linux/amd64 on any host: the recipe builds x86_64 binaries and stubs.
image=igloo-ffmpeg-build:linux_amd64
docker build --platform linux/amd64 -t "$image" "$root"
mkdir -p "$root/cache" "$root/work" "$root/out"
docker run --rm \
  --platform linux/amd64 \
  -u "$(id -u):$(id -g)" \
  -e HOME=/build/work/home \
  -e JOBS="${JOBS:-$(nproc)}" \
  -v "$root:/build" \
  "$image" bash /build/scripts/build-linux.sh
