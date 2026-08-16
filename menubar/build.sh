#!/bin/bash
#
# メニューバーアプリのビルド。フル Xcode は不要（Command Line Tools で通る）。
#
#   ./build.sh          → dist/Enddayd.app
#   ./build.sh --run    → ビルドして起動
#
set -euo pipefail
cd "$(dirname "$0")"

APP=dist/Enddayd.app
MIN=14.0

rm -rf build dist
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Swift 6 言語モードでも通ることを確かめる。並行性の指摘は現在の既定だと
# 警告どまりで、ビルドは成功してしまう。6 に切り替わってから直すことになると
# 「ビルドできない」状態から始まるので、通るうちに落としておく。
swiftc -parse-as-library -swift-version 6 -typecheck \
  -target "arm64-apple-macos${MIN}" Sources/Enddayd/*.swift

# arm64 と x86_64 の両方を作って束ねる（配布先の CPU を選ばない）
for arch in arm64 x86_64; do
  swiftc -parse-as-library -O \
    -target "${arch}-apple-macos${MIN}" \
    -o "build/Enddayd-${arch}" \
    Sources/Enddayd/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Enddayd" build/Enddayd-arm64 build/Enddayd-x86_64

cp Info.plist "$APP/Contents/Info.plist"

# アイコン。各サイズを実寸で描き直す
./icon/build-icns.sh "$PWD/build/Enddayd.icns" >/dev/null
cp build/Enddayd.icns "$APP/Contents/Resources/Enddayd.icns"

# デーモン本体を同梱する。アプリの「導入する」はこれを install する
cp ../enddayd.sh "$APP/Contents/Resources/enddayd.sh"
chmod 755 "$APP/Contents/Resources/enddayd.sh"

# ad-hoc 署名。配布に耐える署名（Developer ID + 公証）は別途
codesign --force --sign - "$APP"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --verify "$APP"
lipo -info "$APP/Contents/MacOS/Enddayd"
echo "built: $PWD/$APP"

if [ "${1:-}" = "--run" ]; then
  open "$APP"
fi
