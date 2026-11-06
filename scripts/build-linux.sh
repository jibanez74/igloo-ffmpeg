#!/usr/bin/env bash
# Runs inside the build container (see ../Dockerfile and ../build.sh) and
# writes out/linux_amd64/. common.sh does the shared work; this file adds the
# toolchain, the Linux-only dependencies (NVIDIA, Intel QSV) and their
# configure options.
set -euo pipefail
source /opt/rh/gcc-toolset-15/enable

B=/build
PLATFORM=linux_amd64
CFLAGS="-O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -pthread"
LDFLAGS="-static-libgcc -static-libstdc++ -Wl,-z,relro,-z,now -pthread"
source "$B/scripts/common.sh"
export CFLAGS="-I$PREFIX/include $CFLAGS"
export CXXFLAGS=$CFLAGS
export LDFLAGS="-L$PREFIX/lib $LDFLAGS"

# zimg.pc asks for -lstdc++; with the archive first on the -L path that
# resolves statically, so the binaries need no libstdc++.so or libgcc_s.
ln -sf "$(g++ -print-file-name=libstdc++.a)" "$PREFIX/lib/libstdc++.a"

# The stubbed libdrm and libva also depend on gen_implib and Implib.so's ref.
stamp_extra() {
  if [[ $1 == libdrm || $1 == libva ]]; then
    declare -f gen_implib
    lock_field implib 3
  fi
}

# gen_implib <lib.so> <lib.a>: a static stub that dlopens the host's library on
# first use, so ffmpeg starts on hosts without it and uses the host's VA-API
# stack (and drivers) when present. Same approach as Jellyfin/BtbN builds.
gen_implib() {
  local tmp
  tmp=$(mktemp -d "$WORK/implib.XXXXXX")
  (
    cd "$tmp"
    python3.12 "$SRC/implib/implib-gen.py" --target x86_64-linux-gnu --dlopen --lazy-load "$1" > /dev/null
    gcc $CFLAGS -fvisibility=hidden -Wa,--noexecstack -DIMPLIB_HIDDEN_SHIMS -c ./*.tramp.S ./*.init.c
    ar -rcs "$2" ./*.tramp.o ./*.init.o
  )
  rm -rf "$tmp"
}

build_ffnvcodec() {
  cd "$SRC/ffnvcodec"
  make PREFIX="$PREFIX" install
}

build_libvpl() {
  cd "$SRC/libvpl"
  cmake -GNinja -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DINSTALL_DEV=ON -DINSTALL_LIB=ON -DINSTALL_EXAMPLES=OFF \
    -DBUILD_EXAMPLES=OFF -DBUILD_EXPERIMENTAL=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF
  ninja -C build -j"$JOBS"
  ninja -C build install
}

# libdrm and libva are built shared only to generate the implib stubs above.
build_libdrm() {
  cd "$SRC/libdrm"
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release -Ddefault_library=shared \
    -Dudev=false -Dtests=false -Dman-pages=disabled -Dcairo-tests=disabled -Dvalgrind=disabled \
    -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
    -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled \
    -Detnaviv=disabled
  ninja -C build -j"$JOBS"
  ninja -C build install
}

build_libva() {
  cd "$SRC/libva"
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release -Ddefault_library=shared \
    -Denable_docs=false -Ddisable_drm=false -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no
  ninja -C build -j"$JOBS"
  ninja -C build install
  gen_implib "$PREFIX/lib/libdrm.so.2" "$PREFIX/lib/libdrm.a"
  gen_implib "$PREFIX/lib/libva.so.2" "$PREFIX/lib/libva.a"
  gen_implib "$PREFIX/lib/libva-drm.so.2" "$PREFIX/lib/libva-drm.a"
  rm -f "$PREFIX"/lib/libdrm*.so* "$PREFIX"/lib/libva*.so*
}

# build_libva turns libdrm's shared library into a stub and deletes it, so a
# change to either pin rebuilds both: libva needs the real libdrm.so.2, and a
# reinstalled libdrm.so would otherwise be linked instead of the stub.
if ! built libdrm || ! built libva; then
  rm -f "$STAMPS/libdrm" "$STAMPS/libva"
fi
build_deps implib zlib x264 zimg dav1d ffnvcodec libvpl libdrm libva

# NVIDIA (NVENC, the nvdec hwaccel, CUDA filters) and Intel QSV. NVIDIA
# decode is the nvdec hwaccel (-hwaccel cuda); the separate *_cuvid decoders
# are not built.
ENCODERS+=(h264_nvenc h264_qsv)
FILTERS+=(scale_cuda tonemap_cuda scale_qsv)
# g++ links the executables so -static-libstdc++ applies to zimg and libvpl.
build_ffmpeg \
  --cc=gcc --cxx=g++ --ld=g++ --nvcc=clang \
  --extra-ldexeflags=-pie --extra-libs=-ldl \
  --enable-ffnvcodec --enable-cuda --enable-cuda-llvm --enable-nvdec --enable-nvenc \
  --enable-libvpl --enable-vaapi --enable-libdrm

toolchain_info() {
  echo "base image: $(grep -m1 '^FROM ' "$B/Dockerfile" | cut -d' ' -f2)"
  gcc --version | head -1
  clang --version | head -1
  rpm -q gcc-toolset-15-gcc gcc-toolset-15-binutils clang nasm cmake
  echo "meson $(meson --version), ninja $(ninja --version)"
}
package
