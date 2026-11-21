#!/bin/bash
# Scripts/make_icon.swift 로 PNG를 그리고 Resources/AppIcon.icns 로 변환
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

swift Scripts/make_icon.swift "$TMP/icon_1024.png"

for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon.png
echo "생성: Resources/AppIcon.icns"
