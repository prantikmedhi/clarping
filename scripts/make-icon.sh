#!/bin/bash
# Packages the brand app icon (assets/brand/icon-1024.png, the Split Spark on
# the macOS icon grid) as build/AppIcon.icns: every iconset size with sips,
# then iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/brand/icon-1024.png"
OUT="$ROOT/build"
SET="$OUT/AppIcon.iconset"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
rm -rf "$SET"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -s format png -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  if [ $d -eq 1024 ]; then
    cp "$SRC" "$SET/icon_${s}x${s}@2x.png"
  else
    sips -s format png -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  fi
done
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
echo "Wrote $OUT/AppIcon.icns"
