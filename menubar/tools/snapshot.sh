#!/bin/bash
#
# 設定画面を画面に出さずに PNG へ落とす。見た目の確認と退行の発見に使う。
#
#   ./tools/snapshot.sh [出力先]     既定は ./snapshots（build.sh が build/ を消すので分けてある）
#
# ウィンドウは前面に出さない（前面に出す実装にすると、裏で何度も回す道具に
# ならない。利用者の画面を奪ってはいけない）。
#
# メニューバーのメニュー自体はネイティブUIなので、この方法では撮れない。
# 撮れるのは設定画面だけ。メニューの見え方は人が開いて確かめること。
#
# 色を見るときの注意: SwiftUI 側で地を塗っている。塗らずに cacheDisplay すると
# RGB が全部 0 でアルファだけの絵になり、半透明を合成せずに測るのと同じ
# 読み違いが起きる（実際に一度それで「選択状態が出ていない」と誤読した）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-snapshots}"
mkdir -p "$OUT"

BIN=$(mktemp -d)/snapshot
trap 'rm -rf "$(dirname "$BIN")"' EXIT

swiftc -parse-as-library -swift-version 6 -o "$BIN" \
  Sources/Enddayd/EnforceLevel.swift \
  Sources/Enddayd/ConfParser.swift \
  Sources/Enddayd/LogReader.swift \
  Sources/Enddayd/DaemonProbe.swift \
  Sources/Enddayd/Admin.swift \
  Sources/Enddayd/DaemonModel.swift \
  Sources/Enddayd/ScheduleView.swift \
  tools/Snapshot.swift

"$BIN" "$OUT"
