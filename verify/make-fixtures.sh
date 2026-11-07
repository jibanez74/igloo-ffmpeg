#!/usr/bin/env bash
# Writes a small set of synthetic media files covering what Igloo's probes
# read (codecs, HDR colour tags, audio layouts, subtitles, chapters, tags,
# cover art), for ffprobe-parity.py where no media library is at hand.
#   make-fixtures.sh <ffmpeg> <output dir>
set -euo pipefail
ffmpeg=$1 dir=$2
mkdir -p "$dir"
run() { "$ffmpeg" -hide_banner -nostdin -v error -y "$@"; }
video=(-f lavfi -i testsrc2=s=640x360:r=24:d=4)
sine=(-f lavfi -i sine=f=440:d=4)

printf '1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:03,500\nWorld\n' > "$dir/subs.srt"
printf ';FFMETADATA1\ntitle=Fixture\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=Two\n' > "$dir/chapters.txt"

# H.264 + AAC stereo MP4 with tags and chapters
run "${video[@]}" "${sine[@]}" -i "$dir/chapters.txt" -map 0 -map 1 -map_metadata 2 -map_chapters 2 \
  -c:v libx264 -preset veryfast -c:a aac -ac 2 -metadata:s:a:0 language=eng "$dir/sdr.mp4"
# 10-bit H.264 tagged PQ/BT.2020 (Igloo's HDR detection) with 5.1 E-AC-3 in MOV
run -f lavfi -i testsrc2=s=1280x720:r=24:d=2 -f lavfi -i "sine=d=2,aformat=channel_layouts=5.1" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -c:a eac3 "$dir/hdr.mov"
# Matroska: H.264, AC-3 5.1 and AAC stereo audio, a forced SRT and a default WebVTT track
run "${video[@]}" -f lavfi -i "sine=d=4,aformat=channel_layouts=5.1" "${sine[@]}" -i "$dir/subs.srt" -i "$dir/subs.srt" \
  -map 0 -map 1 -map 2 -map 3 -map 4 -c:v libx264 -preset veryfast -c:a:0 ac3 -c:a:1 aac \
  -c:s:0 srt -c:s:1 webvtt -metadata:s:a:0 language=spa -metadata:s:a:1 title=Commentary \
  -metadata:s:s:0 language=eng -disposition:s:0 forced -disposition:s:1 default "$dir/multi.mkv"
# AVI: H.264 and PCM
run "${video[@]}" "${sine[@]}" -c:v libx264 -preset veryfast -c:a pcm_s16le "$dir/legacy.avi"
# Music: FLAC with tags and cover art, AAC in M4A
run -f lavfi -i color=c=blue:s=300x300:d=1 -frames:v 1 "$dir/cover.jpg"
run "${sine[@]}" -i "$dir/cover.jpg" -map 0 -map 1 -c:a flac -c:v mjpeg -disposition:v attached_pic \
  -metadata title=Song -metadata artist=Artist -metadata album_artist=Artist -metadata album=Album \
  -metadata genre=Rock -metadata track=3/10 -metadata disc=1/2 -metadata date=2024 "$dir/song.flac"
run "${sine[@]}" -c:a aac -metadata title=Tune -metadata artist=Artist -metadata album=Album "$dir/tune.m4a"
rm -f "$dir/subs.srt" "$dir/chapters.txt" "$dir/cover.jpg"
ls "$dir"
