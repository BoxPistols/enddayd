#!/bin/bash
#
# アプリの更新を配るReleaseを作る。
#
#   ./release.sh            ビルドしてdist/Enddayd-<版>.zipを作るだけ
#   ./release.sh --publish  さらにGitHubにv<版>のReleaseを作ってzipを添付する
#
# 各Macのアプリは1日1回releases/latestを見て、Info.plistの版より新しければ
# 知らせる（Sources/Enddayd/Updater.swift）。版を上げずにReleaseを作っても誰にも届かない。
#
# CIでは作らない。macOSのジョブは無料枠を10倍で消費するため、手元でビルドする。
#
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ZIP="dist/Enddayd-${VERSION}.zip"

# Command Line ToolsのswiftcにはSwiftUIのマクロのプラグインが無く、ビルドが通らない
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Releaseのタグと添付のzipが同じソースを指すように、コミット済みで、pushしたmainと
# 同じ状態のときだけ作る
if [ "${1:-}" = "--publish" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "コミットしていない変更があります。Releaseはコミット済みの状態から作ります" >&2
    exit 1
  fi
  git fetch -q origin main
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "いまのコミットがorigin/mainと違います。mainを取り込んでから作ってください" >&2
    exit 1
  fi
fi

./build.sh
# Finderの圧縮と同じ形式。zipコマンドだとアプリの拡張属性と署名が崩れることがある
/usr/bin/ditto -c -k --keepParent dist/Enddayd.app "$ZIP"
echo "zip: $PWD/$ZIP"

if [ "${1:-}" = "--publish" ]; then
  if gh release view "v${VERSION}" >/dev/null 2>&1; then
    echo "v${VERSION} のReleaseはもうあります。Info.plistの版を上げてください" >&2
    exit 1
  fi
  gh release create "v${VERSION}" "$ZIP" --target "$(git rev-parse HEAD)" --title "v${VERSION}" --generate-notes
fi
