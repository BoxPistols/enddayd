#!/usr/bin/env bash
#
# テストを実行し、宣言した件数だけ実際に実行されたかを確認する。
#
# bats 1.11 以降はテスト名に非 ASCII が含まれると「unknown test name」として
# 読み飛ばす（1.10 以前は実行できる）。bats 自身も失敗を返すが、出るのは
# 大量の unknown test name 行と警告1行だけで、何件が実行されなかったのかは
# TAP を数えないと分からない。計画数と実行数を突き合わせて明示的に落とす。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

tap=$(mktemp)
trap 'rm -f "$tap"' EXIT

bats --formatter tap tests/ | tee "$tap"
status=${PIPESTATUS[0]}

planned=$(sed -n 's#^1\.\.\([0-9][0-9]*\)$#\1#p' "$tap" | head -1)
executed=$(grep -cE '^(ok|not ok) ' "$tap" || true)

echo
echo "planned=${planned:-0} executed=${executed:-0}"

if [ -z "$planned" ] || [ "$planned" -eq 0 ]; then
  echo "テストが1件も宣言されていません" >&2
  exit 1
fi

if [ "$planned" != "$executed" ]; then
  echo "宣言 ${planned} 件に対して ${executed} 件しか実行されていません。" >&2
  echo "テスト名に非 ASCII が混ざっていないか確認してください。" >&2
  exit 1
fi

exit "$status"
