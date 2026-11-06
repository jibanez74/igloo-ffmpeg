# Shared by build-linux.sh and build-macos.sh, which set B (the repository
# root) and PLATFORM (linux_amd64, darwin_arm64) and then source this file.
# It fetches and verifies the sources in ../sources.lock, builds the static
# dependencies both platforms share, applies ../patches to FFmpeg, and
# packages out/<platform>/ plus the corresponding-source bundle.
set -euo pipefail
# Keep errexit inside $(...) too: fetch runs in one, and a failed submodule
# update must not leave an incomplete tree in the source cache.
shopt -s inherit_errexit

CACHE=$B/cache
WORK=$B/work/$PLATFORM
SRC=$WORK/src
PREFIX=$WORK/prefix
STAMPS=$WORK/stamps
OUT=$B/out/$PLATFORM
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
# GNU tar: the normalized source tarballs need --sort, --mtime and --transform.
TAR=${TAR:-tar}
mkdir -p "$HOME" "$CACHE" "$SRC" "$PREFIX/lib" "$STAMPS" "$OUT"
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig

die() { echo "build-$PLATFORM: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# sha256 <file>...: sha256sum's output, also where only shasum exists (macOS).
sha256() {
  if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# lock_field <name> <column>: 2=kind 3=ref 4=sha256 5=url
lock_field() {
  awk -v n="$1" -v c="$2" '$1 == n { print $c; found = 1 } END { exit !found }' "$B/sources.lock" ||
    die "$1 is not in sources.lock"
}

# fetch <name>: makes sure $CACHE holds the verified source tarball and prints its path.
fetch() {
  local name=$1 kind ref sha url tarball tmp attempt
  kind=$(lock_field "$name" 2)
  ref=$(lock_field "$name" 3)
  sha=$(lock_field "$name" 4)
  url=$(lock_field "$name" 5)
  if [[ $kind == tar ]]; then
    tarball=$CACHE/$(basename "$url")
    if [[ ! -f $tarball ]]; then
      # Retry every failure: curl's own --retry skips connection failures,
      # which is how ffmpeg.org fails, and the image's curl predates
      # --retry-all-errors.
      for attempt in 1 2 3 4 5; do
        curl -fsSL --connect-timeout 30 -o "$tarball.part" "$url" >&2 && break
        (( attempt < 5 )) || die "$name: download failed: $url"
        sleep $((attempt * 10))
      done
      mv "$tarball.part" "$tarball"
    fi
    [[ $(sha256 "$tarball" | cut -d' ' -f1) == "$sha" ]] || die "$name: sha256 mismatch for $tarball"
  else
    # Git sources are pinned by commit. The tree, submodules included, is
    # packed once into a normalized tarball that also goes into the
    # corresponding-source bundle.
    tarball=$CACHE/$name-$ref.tar.gz
    if [[ ! -f $tarball ]]; then
      tmp=$(mktemp -d "$WORK/fetch-$name.XXXXXX")
      git -C "$tmp" init -q
      git -C "$tmp" fetch -q --depth 1 "$url" "$ref"
      git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
      [[ $(git -C "$tmp" rev-parse HEAD) == "$ref" ]] || die "$name: fetched commit is not $ref"
      git -C "$tmp" submodule -q update --init --recursive --depth 1
      "$TAR" -C "$tmp" --exclude=.git --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
        --transform "s,^\.,$name-$ref," -cf - . | gzip -n -9 > "$tarball.part"
      mv "$tarball.part" "$tarball"
      rm -rf "$tmp"
    fi
  fi
  echo "$tarball"
}

# unpack <name>: fresh source tree at $SRC/<name>.
unpack() {
  local tarball
  tarball=$(fetch "$1")
  rm -rf "${SRC:?}/$1"
  mkdir -p "$SRC/$1"
  "$TAR" -xf "$tarball" -C "$SRC/$1" --strip-components=1
}

# stamp_key <name>: a digest of everything a dependency's build depends on: its
# source ref, its build function, the shared flags and the platform's
# toolchain_id, plus whatever the platform's stamp_extra adds. Changing any of
# them rebuilds the dependency.
stamp_key() {
  {
    lock_field "$1" 3
    declare -f "build_$1" || true
    echo "$CFLAGS|$CXXFLAGS|$LDFLAGS"
    toolchain_id
    if declare -F stamp_extra > /dev/null; then stamp_extra "$1"; fi
  } | sha256 | cut -d' ' -f1
}
# built <name>: true when <name> was already built from its current inputs.
built() { [[ -f $STAMPS/$1 && $(< "$STAMPS/$1") == "$(stamp_key "$1")" ]]; }
mark_built() { stamp_key "$1" > "$STAMPS/$1"; }

# build_deps <name>...: builds each dependency whose inputs changed.
build_deps() {
  local dep
  for dep in "$@"; do
    if built "$dep"; then
      log "$dep: up to date"
      continue
    fi
    log "$dep: building"
    unpack "$dep"
    if declare -F "build_$dep" > /dev/null; then "build_$dep"; fi
    mark_built "$dep"
  done
}

build_zlib() {
  cd "$SRC/zlib"
  ./configure --prefix="$PREFIX" --static
  make -j"$JOBS"
  make install
}

# No OpenCL: Igloo never enables x264's OpenCL lookahead, and its Makefile
# embeds the kernel sources in directory-listing order (make 4.2 does not sort
# $(wildcard)), which made the binaries differ from host to host.
build_x264() {
  cd "$SRC/x264"
  ./configure --prefix="$PREFIX" --disable-cli --enable-static --enable-pic --disable-lavf --disable-swscale \
    --disable-opencl
  make -j"$JOBS"
  make install
}

build_zimg() {
  cd "$SRC/zimg"
  ./autogen.sh
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic
  make -j"$JOBS"
  make install
}

build_dav1d() {
  cd "$SRC/dav1d"
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Denable_tools=false -Denable_tests=false
  ninja -C build -j"$JOBS"
  ninja -C build install
}

# Components. A static link carries every registered component in both
# binaries, so the sets Igloo itself chooses are allowlists: the encoders,
# muxers and filters its argument chains, capability probes and tests name
# (verify/required-features.txt), plus what the ffmpeg CLI picks or inserts
# on its own. Adding one means adding it here (or to a platform's additions
# in its build script) and to required-features.txt.
#
# Encoders: required-features, the CLI's defaults for -f null and framecrc
# (wrapped_avframe, pcm_s16le), and the testdata READMEs' fixture recipes
# (mjpeg, flac).
ENCODERS=(
  libx264
  aac ac3 eac3
  webvtt srt subrip movtext
  dca wavpack dvdsub pcm_f32le rawvideo
  wrapped_avframe pcm_s16le mjpeg flac
)
# Muxers: required-features (hls selects mov and mpegts itself) and the
# fixture recipes' outputs.
MUXERS=(
  hls mp4 mov mpegts matroska webvtt framecrc null rawvideo pcm_f32le
  avi image2 flac ipod
)
# Filters: the HLS chains and capability probes, the ones the CLI inserts
# (format negotiation, -ar/-ac, accurate seek, autorotate), and the test
# sources. buffer/buffersink are always built.
FILTERS=(
  scale format setparams yadif zscale tonemap aresample hwupload
  null anull aformat trim atrim transpose hflip vflip rotate
  testsrc2 color sine anullsrc aevalsrc tinterlace setfield crop silencedetect
)
# Decoders and demuxers face whatever a library holds, so they are a
# denylist: everything stays except classes no media library carries (game,
# console and demo formats, screen and webcam capture, still-image formats
# other than cover art, telephony and speech codecs) and the hardware
# decoders Igloo never selects (*_qsv; NVIDIA decodes through nvdec).
# Mainstream, legacy-PC, broadcast and professional formats all stay.
DENY_DECODERS=(
  # video: games, consoles, demos
  fourxm anm argo bethsoftvid bfi bink bmv_video c93 cdtoons cdxl dfa dsicinvideo dxa
  eacmv eamad eatgq eatgv eatqi escape124 escape130 gdv hnm4_video idcin interplay_video
  ipu jv kmvc mdec mmvideo mobiclip motionpixels paf_video rl2 roq sanm sga
  simbiosis_imx smacker thp tiertexseqvideo tmv truemotion1 truemotion2 truemotion2rt
  txd vb vmdvideo vqa xan_wc3 xan_wc4 yop flic
  # video: screen, game and webcam capture, remote desktop
  arbc cscd tscc cpia dxtory fic flashsv flashsv2 fmvc fraps g2m lscr mimic msa1
  mss1 mss2 mwsc rasc rscc scpr screenpresso srgc tdsc tscc2 vmnc wcmv zmbv
  # video: text art, toys, oddities
  ansi bintext idf xbin aura aura2 cdgraphics imm4 imm5 mxpeg pdv wnv1 vnull dxv notchlc
  # still images other than cover-art formats
  alias_pix brender_pix dds exr fits gem hdr pam pbm pcx pfm pgm pgmyuv pgx phm photocd
  pictor ppm psd ptx qoi sgi sunrast targa vbn wbmp xbm xface xpm xwd
  # audio: games, consoles, demos
  eightsvx_exp eightsvx_fib adpcm_4xm adpcm_adx adpcm_afc adpcm_agm adpcm_aica adpcm_argo
  adpcm_circus adpcm_ct adpcm_dtk adpcm_ea adpcm_ea_maxis_xa adpcm_ea_r1 adpcm_ea_r2
  adpcm_ea_r3 adpcm_ea_xas adpcm_ima_acorn adpcm_ima_alp adpcm_ima_amv adpcm_ima_apc
  adpcm_ima_apm adpcm_ima_cunning adpcm_ima_dat4 adpcm_ima_dk3 adpcm_ima_dk4
  adpcm_ima_ea_eacs adpcm_ima_ea_sead adpcm_ima_escape adpcm_ima_hvqm2 adpcm_ima_hvqm4
  adpcm_ima_iss adpcm_ima_magix adpcm_ima_moflex adpcm_ima_mtf adpcm_ima_pda adpcm_ima_rad
  adpcm_ima_smjpeg adpcm_ima_ssi adpcm_ima_ws adpcm_ima_xbox adpcm_mtaf adpcm_n64 adpcm_psx
  adpcm_psxc adpcm_sanyo adpcm_thp adpcm_thp_le adpcm_vima adpcm_xa adpcm_xmd adpcm_zork
  ahx atrac9 binkaudio_dct binkaudio_rdft bmv_audio cbd2_dpcm derf_dpcm dsicinaudio
  gremlin_dpcm hca interplay_dpcm interplay_acm paf_audio pcm_sga roq_dpcm sdx2_dpcm
  smackaud sol_dpcm vmdaudio wady_dpcm ws_snd1 xan_dpcm xma1 xma2 ftr fastaudio
  # audio: telephony, speech, Bluetooth, oddities
  acelp_kelvin adpcm_ima_oki adpcm_sbpro_2 adpcm_sbpro_3 adpcm_sbpro_4 adpcm_g722 adpcm_g726
  adpcm_g726le g723_1 g728 g729 comfortnoise dss_sp evrc ilbc msnsiren qcelp siren truespeech
  sbc aptx aptx_hd dfpwm misc4 bonk osq rka wavarc hcom apac qoa pcm_vidc ffwavesynth
  metasound on2avc iac imc
  # hardware decoders Igloo never selects
  av1_qsv h264_qsv hevc_qsv mjpeg_qsv mpeg2_qsv vc1_qsv vp8_qsv vp9_qsv vvc_qsv
)
DENY_DEMUXERS=(
  # games, consoles, demos
  threedostr fourxm ace acm adp ads adx afc aix alp anm argo_asf argo_brp argo_cvg ast
  bethsoftvid bfi bfstm bink binka bmv boa brstm c93 cdxl derf dfa dsicin dxa ea ea_cdata segafilm flic
  fsb fwse gdv genh hca hnm idcin ipmovie ipu jv kvag mca mm mmf mods moflex msf mtaf musx
  mvi paf pp_bnk str redspark rl2 roq rpl rsd scd sdns sga siff simbiosis_imx smacker smush
  svag svs thp tiertexseq tmv txd vag vmd vpk wady wc3 wsaud wsd wsvqa xa xmd xmv xvag
  yop sol
  # capture, CCTV, telephony, oddities
  aea apac apc apm avr avs bit bonk cdg cine codec2 codec2raw dcstr dfpwm dhav dss epaf
  filmstrip fits frm g722 g723_1 g726 g726le g728 g729 hcom hxvs idf iff ifv ilbc
  ingenient iss iv8 kux laf lc3 lmlm4 luodat lvf mgsts msnwc_tcp msp mtv mv nc nistsphere
  nsp pdv pmp pvf qcp qoa rka rso sbc sbg sdr2 sds sdx ser sln sox tedcaptions tty usm
  pcm_vidc vividas vivo voc wavarc wve xbin xwma adf aa aax
  # still images other than cover-art formats
  image2_alias_pix image2_brender_pix image_cri_pipe image_dds_pipe image_exr_pipe
  image_gem_pipe image_hdr_pipe image_pam_pipe image_pbm_pipe image_pcx_pipe image_pfm_pipe
  image_pgm_pipe image_pgmyuv_pipe image_pgx_pipe image_phm_pipe image_photocd_pipe
  image_pictor_pipe image_psd_pipe image_qdraw_pipe image_qoi_pipe image_sgi_pipe
  image_sunrast_pipe image_svg_pipe image_vbn_pipe image_xbm_pipe image_xpm_pipe
  image_xwd_pipe image_jpegxl_pipe jpegxl_anim
)
join() { local IFS=,; echo "$*"; }

# check_names <kind> <name>...: configure silently ignores a component name it
# does not know, and its names can differ from the ones ffmpeg lists (movtext,
# not mov_text). Fail instead of building without a component.
check_names() {
  local kind=$1 known name status=0
  shift
  known=$(./configure "--list-$kind" | tr -s ' \t' '\n')
  for name in "$@"; do
    grep -qx -- "$name" <<< "$known" || { echo "build-$PLATFORM: unknown ${kind%s} \"$name\"" >&2; status=1; }
  done
  return "$status"
}

# Configure options both platforms share. --disable-autodetect makes every
# external feature explicit, so the build never depends on what the host
# happens to contain. It also turns off threads, hence --enable-pthreads.
FFMPEG_COMMON_FEATURES=(
  --enable-gpl
  --disable-autodetect
  --disable-shared --enable-static
  --disable-debug --disable-doc --disable-ffplay --disable-network
  --enable-pthreads --enable-iconv --enable-zlib
  --enable-libx264 --enable-libzimg --enable-libdav1d
)

# build_ffmpeg <configure option>...: unpacks FFmpeg, applies every patch,
# checks the component names and builds with the shared options plus the
# platform's. Call it after the platform added its components to the lists.
build_ffmpeg() {
  local patch
  log "ffmpeg: building"
  unpack ffmpeg
  cd "$SRC/ffmpeg"
  # One source tree for every platform: the CUDA patches only add code that
  # configure leaves out where CUDA is unavailable.
  for patch in "$B"/patches/*.patch; do
    log "applying $(basename "$patch")"
    patch -p1 --forward --fuzz=0 --no-backup-if-mismatch -s < "$patch"
  done
  check_names encoders "${ENCODERS[@]}"
  check_names muxers "${MUXERS[@]}"
  check_names filters "${FILTERS[@]}"
  check_names decoders "${DENY_DECODERS[@]}"
  check_names demuxers "${DENY_DEMUXERS[@]}"
  ./configure --prefix="$WORK/ffmpeg-prefix" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-version=Igloo \
    --extra-cflags="$CFLAGS" --extra-cxxflags="$CXXFLAGS" --extra-ldflags="$LDFLAGS" \
    "${FFMPEG_COMMON_FEATURES[@]}" "$@" \
    --disable-encoders --enable-encoder="$(join "${ENCODERS[@]}")" \
    --disable-muxers --enable-muxer="$(join "${MUXERS[@]}")" \
    --disable-filters --enable-filter="$(join "${FILTERS[@]}")" \
    --disable-indevs --enable-indev=lavfi --disable-outdevs \
    --disable-protocols --enable-protocol=file,pipe \
    --disable-decoder="$(join "${DENY_DECODERS[@]}")" \
    --disable-demuxer="$(join "${DENY_DEMUXERS[@]}")"
  make -j"$JOBS"
}

# package: installs the binaries, writes SHA256SUMS and BUILDINFO (whose
# toolchain section comes from the platform's toolchain_info), and the
# corresponding source for the GPL: every source tarball, the patches and the
# recipe that produced these binaries.
package() {
  local version bundle name sources=()
  log "packaging"
  install -m 0755 "$SRC/ffmpeg/ffmpeg" "$SRC/ffmpeg/ffprobe" "$OUT/"
  if declare -F post_install > /dev/null; then post_install; fi
  (cd "$OUT" && sha256 ffmpeg ffprobe > SHA256SUMS)

  {
    echo "Igloo FFmpeg build, $PLATFORM"
    echo
    "$OUT/ffmpeg" -hide_banner -version | sed -n 1p
    echo
    echo "## Toolchain"
    toolchain_info
    echo
    echo "## Configure"
    grep -m1 '^FFMPEG_CONFIGURATION=' "$SRC/ffmpeg/ffbuild/config.mak" | cut -d= -f2-
    echo
    echo "## Sources (sources.lock)"
    grep -v '^#' "$B/sources.lock"
    echo
    echo "## Patches"
    (cd "$B/patches" && sha256 ./*.patch)
    echo
    echo "## Binaries"
    cat "$OUT/SHA256SUMS"
  } > "$OUT/BUILDINFO"

  log "done: $OUT"
  ls -l "$OUT"
  # One bundle covers every platform: the same sources, patches and scripts.
  # The Linux build writes it; the macOS build sets SOURCE_BUNDLE=0.
  [[ ${SOURCE_BUNDLE:-1} == 1 ]] || return 0
  version=$(lock_field ffmpeg 3)
  bundle=$B/out/igloo-ffmpeg-$version-sources.tar
  for name in $(awk '!/^#/ && NF { print $1 }' "$B/sources.lock"); do
    sources+=("cache/$(basename "$(fetch "$name")")")
  done
  "$TAR" -C "$B" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$bundle" \
    Dockerfile build.sh sources.lock scripts patches "${sources[@]}"
  ls -l "$bundle"
}
