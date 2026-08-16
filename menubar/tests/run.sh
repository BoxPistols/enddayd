#!/bin/bash
#
# メニューバーアプリのテスト。
#
# 画面や権限に触らない部分（設定の解釈・ログの読み取り）だけを取り出して
# 実行する。XCTest はフル Xcode を要求するので使わない。ビルドと同じく
# Command Line Tools だけで通る。
#
#   ./tests/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# テスト対象は Foundation しか使わないファイルに限る。ここに DaemonModel を
# 足したくなったら、それは画面や権限から切り離せていない合図。
swiftc -parse-as-library -swift-version 6 \
  -o "$OUT/tests" \
  Sources/Enddayd/EnforceLevel.swift \
  Sources/Enddayd/ConfParser.swift \
  Sources/Enddayd/LogReader.swift \
  Sources/Enddayd/TodayOverride.swift \
  tests/Harness.swift \
  tests/ConfParserTests.swift \
  tests/LogReaderTests.swift \
  tests/TodayOverrideTests.swift \
  tests/TestMain.swift

"$OUT/tests"
