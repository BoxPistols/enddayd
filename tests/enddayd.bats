#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
  # 既定: 平日 18:00 / 18:30 / 18:45 / 18:50、猶予10分
  write_conf_file \
    'TIMES="18:00,18:30,18:45,18:50"' \
    'WEEKDAYS="1,2,3,4,5,6,7"' \
    'LEVEL="normal"' \
    'LOGOUT_ATTEMPT="1"' \
    'ALLOW_BYPASS="1"' \
    'KILL_GRACE="10"'
}

# --- ステージ境界 -------------------------------------------------------

@test "17:59 は何もしない" {
  run run_at 1079
  [[ "$output" == *"out of window"* ]]
}

@test "18:00 は予告" {
  run run_at 1080
  [[ "$output" == *"stage=notice"* ]]
}

@test "18:29 はまだ予告の範囲" {
  run run_at 1109
  [[ "$output" == *"stage=notice"* ]]
}

@test "18:30 は警告" {
  run run_at 1110
  [[ "$output" == *"stage=warn"* ]]
}

@test "18:45 は最終通告" {
  run run_at 1125
  [[ "$output" == *"stage=final"* ]]
}

@test "18:50 は強制終了" {
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

@test "猶予内（19:00）はまだ強制終了する" {
  run run_at 1140
  [[ "$output" == *"stage=enforce"* ]]
}

@test "猶予を過ぎたら（19:01）何もしない" {
  run run_at 1141
  [[ "$output" == *"out of window"* ]]
}

@test "猶予分数は設定で変えられる" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="0"'
  run run_at 1131
  [[ "$output" == *"out of window"* ]]
}

# --- 曜日 ---------------------------------------------------------------

@test "対象外の曜日では発火しない" {
  # 曜日判定は時刻判定より前に行われるので、時刻を強制しない実行で確認する
  local today other
  today=$(date +%u)
  other=$(( today % 7 + 1 ))
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$other\"" 'LEVEL="normal"'
  run env ENDDAYD_DRY_RUN=1 bash "$SCRIPT" run
  [[ "$output" == *"not a scheduled weekday"* ]]
}

@test "対象の曜日なら曜日判定を通過する" {
  local today
  today=$(date +%u)
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$today\"" 'LEVEL="normal"'
  run env ENDDAYD_DRY_RUN=1 bash "$SCRIPT" run
  [[ "$output" != *"not a scheduled weekday"* ]]
}

@test "ステージ強制指定は曜日判定を迂回する（リハーサル用）" {
  local today other
  today=$(date +%u)
  other=$(( today % 7 + 1 ))
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$other\"" 'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# --- 当日スキップ -------------------------------------------------------

@test "当日日付のスキップファイルがあれば止まる" {
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"bypass file for today"* ]]
}

@test "別の日付のスキップファイルは効かない" {
  echo "2000-01-01" >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

@test "ALLOW_BYPASS=0 ならスキップファイルを無視する" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'ALLOW_BYPASS="0"' 'KILL_GRACE="10"'
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# --- レベル -------------------------------------------------------------

@test "レベルがログに残る" {
  for lv in notify soft normal hard; do
    write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                    "LEVEL=\"$lv\"" 'KILL_GRACE="10"'
    run run_at 1130
    [[ "$output" == *"level=$lv"* ]]
  done
}

@test "ドライラン中は実際の終了処理に進まない" {
  run run_at 1130
  [[ "$output" == *"would execute"* ]]
}

# --- 警告ステージ -------------------------------------------------------

@test "ログアウト試行が有効なら起動中アプリを記録する" {
  run run_at 1110
  [[ "$output" == *"running apps"* ]]
}

@test "LOGOUT_ATTEMPT=0 ならログアウトを試みない" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'LOGOUT_ATTEMPT="0"'
  run run_at 1110
  [[ "$output" == *"logout attempt disabled"* ]]
}

# --- 時刻の設定 ---------------------------------------------------------

@test "設定した時刻に追従する" {
  write_conf_file 'TIMES="09:00,09:30,09:45,09:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 540
  [[ "$output" == *"stage=notice"* ]]
  run run_at 1130
  [[ "$output" == *"out of window"* ]]
}

# --- plist 生成 ---------------------------------------------------------

@test "plist は曜日×時刻の数だけエントリを持つ" {
  run bash "$SCRIPT" plist
  [ "$status" -eq 0 ]
  count=$(echo "$output" | grep -c "<key>Weekday</key>")
  [ "$count" -eq 28 ]   # 7曜日 × 4時刻
}

@test "plist は run サブコマンドを呼ぶ" {
  run bash "$SCRIPT" plist
  [[ "$output" == *"<string>run</string>"* ]]
}
