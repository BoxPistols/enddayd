#!/bin/bash
#
# make-icon.swift から Enddayd.icns を組む。
# 各サイズを個別に描き直す（縮小ではなく実寸で描く）ので、16pt でも線が痩せない。
#
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-Enddayd.icns}"
SET=$(mktemp -d)/Enddayd.iconset
mkdir -p "$SET"

render() { swift make-icon.swift "$SET/$2" "$1"; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "built: $PWD/$OUT"
