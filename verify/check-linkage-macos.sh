#!/usr/bin/env bash
# Fails unless each macOS binary is arm64, links only the system's libraries
# and frameworks, needs nothing newer than macOS 12.0, and carries a valid
# (ad-hoc) code signature.
#   check-linkage-macos.sh <binary>...
set -euo pipefail
MAX_MINOS=12.0
status=0
for bin in "$@"; do
  name=$(basename "$bin")
  [[ $(lipo -archs "$bin") == arm64 ]] || { echo "$name: not an arm64-only binary"; status=1; }
  libs=$(otool -L "$bin" | tail -n +2 | awk '{ print $1 }')
  for lib in $libs; do
    case $lib in
      /usr/lib/libSystem.B.dylib | /usr/lib/libiconv.2.dylib | /usr/lib/libc++.1.dylib | /usr/lib/libobjc.A.dylib) ;;
      /System/Library/Frameworks/*.framework/*) ;;
      *) echo "$name: links $lib, which is not part of macOS"; status=1 ;;
    esac
  done
  minos=$(otool -l "$bin" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1 } found && $1 == "minos" { print $2; exit }')
  # The awk program succeeds when minos is newer than MAX_MINOS.
  if [[ -z $minos ]] || awk -v a="$minos" -v b="$MAX_MINOS" 'BEGIN {
      n = split(a, x, "."); m = split(b, y, ".")
      for (i = 1; i <= (n > m ? n : m); i++) if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 > y[i] + 0)
      exit 1 }'; then
    echo "$name: needs macOS ${minos:-?}, newer than $MAX_MINOS"
    status=1
  fi
  codesign --verify --strict "$bin" || { echo "$name: invalid code signature"; status=1; }
  echo "$name: links $(echo $libs | tr ' ' '\n' | sed 's,.*/,,' | sort -u | tr '\n' ' '); macOS $minos"
done
exit "$status"
