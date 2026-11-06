# igloo-ffmpeg

This repository builds the `ffmpeg` and `ffprobe` that [Igloo](https://github.com/jibanez74/Igloo) uses on Linux x64 and macOS ARM64. Igloo's release binaries embed them, and Igloo's CI runs the server tests against the Linux pair. It builds from upstream FFmpeg and upstream dependency releases, plus the patches in [`patches/`](#patches), which this repository maintains.

## Used by Igloo

Igloo pins each release here by download URL and sha256 in [`media-payloads/payloads.lock`](https://github.com/jibanez74/Igloo/blob/dev/media-payloads/payloads.lock). Its `make media-payloads` downloads the current platform's pair, installs it under `server/cmd/internal/{ffmpeg,ffprobe}/`, and refuses a file that does not match its pin. `make build` runs it first, and `make media-bin` also links the pair as `ffmpeg` and `ffprobe` in `server/dist/media-bin/`, for `PATH`.

Paths below that start with `server/` or name `make` targets are in the Igloo repository.

## Build

```bash
./build.sh          # JOBS=<n> limits parallelism
./build.sh --clean  # rebuild the host platform's build, keeping the source cache
```

`build.sh` builds for the host. On Linux it builds `linux_amd64` inside the toolchain container and needs only Docker. On an Apple Silicon Mac it builds `darwin_arm64` natively; that needs Xcode, Homebrew's `bash gnu-tar xz autoconf automake libtool pkgconf`, and `meson` and `ninja` (the workflow installs the versions the Dockerfile pins). Both share `scripts/common.sh`; `scripts/build-linux.sh` and `scripts/build-macos.sh` add each platform's toolchain, dependencies and configure options.

The build writes `out/<platform>/` with these files:

| File | Contents |
| --- | --- |
| `ffmpeg`, `ffprobe` | The binaries |
| `SHA256SUMS` | Checksums of both binaries |
| `BUILDINFO` | Toolchain, configure line, sources and patch digests |

The Linux build also writes `out/igloo-ffmpeg-<version>-sources.tar`. That file is the GPL corresponding source for both platforms, which build from the same sources and patches: every source tarball, the patches and this recipe. `cache/`, `work/` and `out/` are gitignored.

The Linux build is reproducible: a clean build on a workstation and one on a GitHub runner gave byte-identical binaries. (`media-8.1.3-igloo.1` did not, because x264 embedded its OpenCL kernels in directory-listing order; x264 is now built without OpenCL.) The macOS build is reproducible on the same runner image: it pins Xcode in the workflow, writes static archives without timestamps (`ZERO_AR_DATE`) and signs ad hoc, which carries no timestamp, and two workflow runs gave byte-identical binaries.

## Release

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds and checks the recipe on every push and pull request that changes it. Its run keeps the files as a workflow artifact for 14 days. Pushing a tag named `media-<FFmpeg version>-igloo.<n>`, such as `media-8.1.3-igloo.1`, also publishes them as a GitHub release once both platforms have built:

| Release file | Contents |
| --- | --- |
| `ffmpeg_<platform>`, `ffprobe_<platform>` | The binaries, for `linux_amd64` and `darwin_arm64` |
| `BUILDINFO_<platform>` | Each build's `BUILDINFO` |
| `igloo-ffmpeg-<version>-sources.tar` | The corresponding source |
| `SHA256SUMS` | Checksums of all of the above |

The workflow refuses a tag whose FFmpeg version differs from `sources.lock`. A release is never replaced: a rebuild of the same FFmpeg version gets the next `igloo.<n>`.

## What is built

- **Linux toolchain.** `Dockerfile` pins an AlmaLinux 8 image by digest, so the binaries need glibc 2.28 or newer. GCC comes from gcc-toolset-15 and clang (CUDA kernels to PTX) from AppStream.
- **macOS toolchain.** Xcode's clang, pinned to Xcode 16.4 in the workflow, with a deployment target of macOS 12.0. The binaries are arm64 only.
- **Linux linking.** Everything is static except glibc. libva and libdrm are linked through [Implib.so](https://github.com/yugr/Implib.so) stubs that `dlopen` the host's libraries on first use. A host without VA-API can still run ffmpeg, and Intel QSV uses the host's VA-API stack and drivers. NVIDIA (ffnvcodec) and the oneVPL runtime are loaded by FFmpeg and libvpl at runtime anyway.
- **macOS linking.** x264, zimg, dav1d and zlib are static. Only macOS's own libraries stay dynamic: libSystem, libiconv, libc++ (zimg is C++) and the VideoToolbox, CoreMedia, CoreVideo and CoreFoundation frameworks.
- **Sources.** `sources.lock` pins every source. The FFmpeg release tarball is pinned by sha256 and git dependencies by full commit, each the commit of an upstream release tag named on its line. The exceptions name their reason there: x264 has no releases, zimg's last tag predates memory-safety fixes in code `zscale` runs, and Implib.so has no releases.
- **Configure.** `scripts/common.sh` holds the configure line and the component lists both platforms share; each platform script adds its own options and hardware components. `--disable-autodetect` makes every external feature explicit. A static link carries every registered component in both binaries, so the native components are trimmed too:

  | Components | Policy |
  | --- | --- |
  | Encoders, muxers, filters | Allowlists: what Igloo's argument chains, capability probes and tests name, what the ffmpeg CLI picks or inserts on its own, and what the testdata fixture recipes use. Each is also listed in `verify/required-features.txt`. |
  | Input and output devices, protocols | Only the `lavfi` input device and the `file` and `pipe` protocols. |
  | Decoders, demuxers | Denylists, because a library can hold anything. Only classes no media library carries are left out: game, console and demo formats, screen and webcam capture, still-image formats other than cover art, and telephony and speech codecs. The `*_qsv` and `*_cuvid` decoders are left out too, because NVIDIA decode goes through the `nvdec` hwaccel and Intel decode is software. |
  | Parsers, bitstream filters | All, because they are small and muxers insert bitstream filters on their own. |

  To use a new encoder, muxer or filter, add it to its list in `scripts/common.sh` (or to a platform's additions in `scripts/build-linux.sh` or `scripts/build-macos.sh`) under its configure name (`./configure --list-encoders`), and to `verify/required-features.txt` under the name ffmpeg lists at runtime (`ffmpeg -encoders`), with a trailing `linux` or `darwin` if only one platform has it. The two can differ: the subtitle encoder is `movtext` to configure and `mov_text` to ffmpeg. The build script fails on a name configure does not know, and `check-features.py` then fails any build whose binaries lack a required component.

  The external libraries are limited to what Igloo uses:

  | Library | Used for |
  | --- | --- |
  | x264 | CPU encode |
  | zimg | `zscale` HDR tone-mapping |
  | dav1d | software AV1 decode |
  | nv-codec-headers (Linux) | NVENC/NVDEC and CUDA filters, via `cuda-llvm` |
  | libvpl, VA-API, libdrm (Linux) | Intel QSV |
  | VideoToolbox (macOS, system framework) | the `videotoolbox` hwaccel, `h264_videotoolbox`, `scale_vt` |
  | zlib | |

  Libraries Igloo never calls (fdk-aac, x265, SVT-AV1, libvpx, OpenSSL, libass and fonts, OpenCL, Vulkan, libplacebo and others) are left out.
- **nv-codec-headers stays on SDK 12.0** (`n12.0.16.1`, NVIDIA driver 530.41 or newer). The 13.x SDKs require driver 610 or later.

## Patches

`patches/` is applied in file-name order with `--fuzz=0`, so a patch that no longer fits fails the build instead of being applied loosely. Every patch is FFmpeg code under the LGPL, like the files it patches. Both platforms build the same patched tree; the CUDA code is only compiled where configure enables CUDA.

**`tonemap_cuda` (0002–0006).** Igloo's NVIDIA HDR chain ([`server/cmd/internal/ffmpeg/ffmpeg_hls.go`](https://github.com/jibanez74/Igloo/blob/dev/server/cmd/internal/ffmpeg/ffmpeg_hls.go)) uses a CUDA tone-mapping filter that upstream FFmpeg does not have. 0002 to 0004 were imported from [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg) `v8.1.3-1` (`debian/patches/`); this repository now maintains the filter itself and ports it to new FFmpeg releases, without following jellyfin-ffmpeg. 0005 and 0006 are fixes made here.

| File | Contents |
| --- | --- |
| `0002-update-cuda-func-header.patch` | CUDA math functions the filter's kernels need in `compat/cuda/cuda_runtime.h` (imported unchanged) |
| `0003-dither-matrix-from-add-enhanced-cuda-pixfmt-converter-impl.patch` | `libavfilter/dither_matrix.h`, which the filter includes (imported as only that section of Jellyfin's 0003, whose rest replaces upstream's `scale_cuda`) |
| `0004-add-cuda-tonemap-impl.patch` | The `tonemap_cuda` filter, its kernels and helpers (imported unchanged) |
| `0005-igloo-fix-tonemap-cuda-error-handling.patch` | A failed kernel launch or buffer allocation fails the graph instead of sending an empty frame to the encoder; recompiles no longer leak the Dolby Vision buffers and LUT or drop the dither texture; a Dolby Vision peak of 0 falls back to the default |
| `0006-igloo-fix-cuda-frame-texture-double-destroy.patch` | A failed texture setup no longer destroys the textures it created twice |

**Upstream backports (0101 and up).** Fixes from FFmpeg's `release/8.1` branch that are not in a release yet, each a `git format-patch` of the upstream commit named in its first line. They are dropped when the FFmpeg version that contains them is pinned.

| File | Upstream commit | Fixes |
| --- | --- | --- |
| `0101-backport-avcodec-h264-direct-…` | `a35157abb9` | Out-of-bounds read of colocated motion vectors in broken H.264 field pictures |
| `0102-backport-avformat-matroskadec-…` | `ae0c0d3afa` | Float-cast overflow on a huge Matroska duration |
| `0103-backport-avformat-mov-don-t-leak-…` | `45e8e0a3ff` | MOV/MP4 demuxer leak when a realloc fails |
| `0104-backport-avformat-mov-check-ff-mov-read-chnl-…` | `46d899d7a0` | Unchecked error from the MOV channel-layout box |
| `0105-backport-avcodec-aac-fix-null-dereference-…` | `5c4f5744cd` | AAC decoder null dereference in channel configuration |
| `0106-backport-avcodec-aac-aacdec-usac-…` | `c8de997cb1` | xHE-AAC (USAC) element list not checked against the channel configuration |
| `0107-backport-avcodec-aacsbr-template-…` | `29e619e767` | AAC SBR leak on an init failure |
| `0108-backport-libavformat-flvdec-…` | `8dca1586f4` | FLV demuxer reading uninitialized data |
| `0109-backport-avformat-oggparsevorbis-…` | `ad3b795b72` | Chained Ogg Vorbis streams whose headers exceed 64 KiB (large cover art) |

## Verify

```bash
python3 -I verify/check-features.py [--platform linux|darwin] verify/required-features.txt \
  out/linux_amd64/ffmpeg <reference ffmpeg, e.g. Igloo's server/cmd/internal/ffmpeg/ffmpeg_linux_amd64>
python3 -I verify/ffprobe-parity.py <reference ffprobe> out/linux_amd64/ffprobe \
  <report.json> <media dir>...
```

- `required-features.txt` lists every component Igloo's production code and `make test-server` use. `check-features.py` fails when one is missing on the given platform (the host's by default), and with a reference build it also prints the full component diff.
- `ffprobe-parity.py` runs Igloo's exact metadata probes with both binaries and diffs only the fields Igloo reads. Without a media library at hand, `make-fixtures.sh <ffmpeg> <dir>` writes synthetic files that cover what those probes read; the macOS workflow job compares against the previous macOS payload with them.
- `check-linkage.sh` fails when a Linux binary links anything outside glibc or needs a glibc newer than 2.28. `check-linkage-macos.sh` fails when a macOS binary is not arm64-only, links anything outside the system's libraries and frameworks, needs a macOS newer than 12.0, or has an invalid signature.
- `nvidia-parity.sh` runs on a host with an NVIDIA GPU. It runs Igloo's NVENC and CUDA capability probes, then times its SDR (`scale_cuda`) and HDR (`tonemap_cuda`) session chains with both builds and samples each one's picture. It stops if NVENC does not open, and it skips the benchmarks while NVENC is in use.

**macOS on real hardware is not verified by this repository.** GitHub's macOS runners are virtual machines with a paravirtualized Apple GPU. The workflow checks the macOS build's components, linkage, software encode, HLS output and probe parity there, and reports (without failing the run) whether `h264_videotoolbox` encodes, Igloo's `scale_vt` HDR capability chain runs and `-hwaccel videotoolbox` decodes. All three worked on the runner when the macOS build was added. Playback through Igloo on an Apple Silicon Mac has not been tried.

To run Igloo's server test suite on a local build before it is released, point `IGLOO_FFMPEG_PATH` and `IGLOO_FFPROBE_PATH` at `out/linux_amd64/`. Also put a directory of `ffmpeg`/`ffprobe` symlinks first on `PATH`, because the Makefile checks for both commands on `PATH`.

## Bumping

1. Update the FFmpeg line in `sources.lock`. Verify the new tarball's signature before you record its sha256:

   ```bash
   gpg --verify ffmpeg-<v>.tar.xz.asc ffmpeg-<v>.tar.xz
   ```

   The key is FFmpeg's release key, fingerprint `FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`, from <https://ffmpeg.org/ffmpeg-devel.asc>.
2. Drop the backports (0101 and up) the new release contains, and backport any later `release/<major.minor>` fixes worth having. Then make 0002 to 0006 apply to the new tree: where upstream changed the code a patch touches, rebase that patch by hand and rebuild. The `tonemap_cuda` code is this repository's own now; no other project's patch set has to be followed.
3. Bump the dependencies whose upstream projects have published a new release, in `sources.lock`, with the tag on the line.
4. Rebuild, then run the verify scripts here and Igloo's `make check` against the new build. On a host with an NVIDIA GPU, run `nvidia-parity.sh` with the previous release as the reference.
5. Commit, push, and push the next `media-<version>-igloo.<n>` tag. The workflow publishes the release.
6. In Igloo, point the lines of `media-payloads/payloads.lock` at the new release and its sha256s, which match `SHA256SUMS`. Then run `make media-payloads` and `make check`, and update the version references in `docs/ffmpeg.md` and `THIRD_PARTY_NOTICES.md`.

## License

The build scripts, verify scripts and workflow in this repository are under the GNU General Public License version 3 ([`LICENSE`](LICENSE)), like Igloo. The patches are FFmpeg code under the LGPL, as described above. The binaries enable GPL components, so the released executables are under the GPL version 2 or later; each release carries their complete corresponding source.
