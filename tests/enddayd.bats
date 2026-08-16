#!/usr/bin/env bats
#
# テスト名は ASCII にしている。bats 1.11 以降は非 ASCII のテスト名を
# 「unknown test name」として読み飛ばすため（1.10 以前は実行できる）。
# 何を見ているかは各テストの上の日本語コメントに書く。
# 実行漏れの検知は tests/run.sh が計画数と実行数の突き合わせで行う。

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

# 17:59 は何もしない
@test "stage: 17:59 is out of window" {
  run run_at 1079
  [[ "$output" == *"out of window"* ]]
}

# 18:00 は予告
@test "stage: 18:00 is notice" {
  run run_at 1080
  [[ "$output" == *"stage=notice"* ]]
}

# 18:29 はまだ予告の範囲
@test "stage: 18:29 is still notice" {
  run run_at 1109
  [[ "$output" == *"stage=notice"* ]]
}

# 18:30 は警告
@test "stage: 18:30 is warn" {
  run run_at 1110
  [[ "$output" == *"stage=warn"* ]]
}

# 18:45 は最終通告
@test "stage: 18:45 is final" {
  run run_at 1125
  [[ "$output" == *"stage=final"* ]]
}

# 18:50 は強制終了
@test "stage: 18:50 is enforce" {
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# 猶予内（19:00）はまだ強制終了する
@test "stage: 19:00 is still enforce within grace" {
  run run_at 1140
  [[ "$output" == *"stage=enforce"* ]]
}

# 猶予を過ぎたら（19:01）何もしない
@test "stage: 19:01 is past the grace window" {
  run run_at 1141
  [[ "$output" == *"out of window"* ]]
}

# 猶予分数は設定で変えられる
@test "stage: KILL_GRACE shrinks the enforce window" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="0"'
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
  run run_at 1131
  [[ "$output" == *"out of window"* ]]
}

# --- 曜日 ---------------------------------------------------------------

# 対象外の曜日では発火しない
# （曜日判定は時刻判定より前なので、時刻を強制しない実行で確認する）
@test "weekday: does not fire on an unscheduled weekday" {
  local today other
  today=$(date +%u)
  other=$(( today % 7 + 1 ))
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$other\"" 'LEVEL="normal"'
  run env ENDDAYD_DRY_RUN=1 bash "$SCRIPT" run
  [[ "$output" == *"not a scheduled weekday"* ]]
}

# 対象の曜日なら曜日判定を通過する
@test "weekday: passes the check on a scheduled weekday" {
  local today
  today=$(date +%u)
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$today\"" 'LEVEL="normal"'
  run env ENDDAYD_DRY_RUN=1 bash "$SCRIPT" run
  [[ "$output" != *"not a scheduled weekday"* ]]
}

# ステージ強制指定は曜日判定を迂回する（リハーサル用）
@test "weekday: forced stage bypasses the weekday check" {
  local today other
  today=$(date +%u)
  other=$(( today % 7 + 1 ))
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$other\"" 'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# --- 当日スキップ -------------------------------------------------------

# 当日日付のスキップファイルがあれば止まる
@test "bypass: today's date stops the run" {
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"bypass file for today"* ]]
}

# 別の日付のスキップファイルは効かない
@test "bypass: another date does not stop the run" {
  echo "2000-01-01" >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# ALLOW_BYPASS=0 ならスキップファイルを無視する
@test "bypass: ALLOW_BYPASS=0 ignores the skip file" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'ALLOW_BYPASS="0"' 'KILL_GRACE="10"'
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  [[ "$output" == *"stage=enforce"* ]]
}

# --- レベル -------------------------------------------------------------

# レベルがログに残る
@test "level: each level is recorded in the log" {
  for lv in notify soft normal hard; do
    write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                    "LEVEL=\"$lv\"" 'KILL_GRACE="10"'
    run run_at 1130
    [[ "$output" == *"level=$lv"* ]]
  done
}

# ドライラン中は実際の終了処理に進まない
@test "level: dry run never reaches the real shutdown" {
  run run_at 1130
  [[ "$output" == *"would execute"* ]]
}

# --- 警告ステージ -------------------------------------------------------

# ログアウト試行が有効なら起動中アプリを記録する
@test "warn: records running apps when logout is enabled" {
  run run_at 1110
  [[ "$output" == *"running apps"* ]]
}

# LOGOUT_ATTEMPT=0 ならログアウトを試みない
@test "warn: LOGOUT_ATTEMPT=0 skips the logout attempt" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'LOGOUT_ATTEMPT="0"'
  run run_at 1110
  [[ "$output" == *"logout attempt disabled"* ]]
}

# --- 時刻の設定 ---------------------------------------------------------

# 設定した時刻に追従する
@test "times: follows the configured schedule" {
  write_conf_file 'TIMES="09:00,09:30,09:45,09:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 540
  [[ "$output" == *"stage=notice"* ]]
  run run_at 1130
  [[ "$output" == *"out of window"* ]]
}

# --- plist 生成 ---------------------------------------------------------

# plist は曜日×時刻の数だけエントリを持つ
@test "plist: has one entry per weekday and time" {
  run bash "$SCRIPT" plist
  [ "$status" -eq 0 ]
  count=$(echo "$output" | grep -c "<key>Weekday</key>")
  [ "$count" -eq 28 ]   # 7曜日 × 4時刻
}

# plist は run サブコマンドを呼ぶ
@test "plist: invokes the run subcommand" {
  run bash "$SCRIPT" plist
  [[ "$output" == *"<string>run</string>"* ]]
}

# --- 設定の検証 ---------------------------------------------------------
# ここが本丸。壊れた conf で「静かに何もしない」状態に落ちないこと。
# 正常系と同じ "out of window" を出して終わるのが最悪の壊れ方なので、
# それを出していないことまで見る。

# 正常な設定なら stderr には何も出ない（静かな失敗の再発検知）
@test "conf: a valid config produces no stderr" {
  run run_at 1130
  [ "$status" -eq 0 ]
  [ -z "$(stderr_text)" ]
}

# 段階が4つないと拒否する（正常系のログに化けない）
@test "conf: rejects TIMES with fewer than four stages" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"config invalid"* ]]
  [[ "$output" != *"out of window"* ]]
  [[ "$output" != *"stage="* ]]
}

# 拒否した理由はログファイルに残る（status が見せるのは $LOG だけ）
@test "conf: the rejection reason is written to the log file" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [[ "$(log_text)" == *"config invalid"* ]]
  [[ "$(log_text)" == *"TIMES"* ]]
}

# 曜日が空なら拒否する
@test "conf: rejects an empty WEEKDAYS" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS=""' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"config invalid"* ]]
  [[ "$output" == *"WEEKDAYS"* ]]
}

# 猶予が数値でなければ拒否する
@test "conf: rejects a non-numeric KILL_GRACE" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="ten"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"KILL_GRACE"* ]]
}

# スケジュールの必須項目が欠けた conf は既定値で補わず拒否する
@test "conf: rejects a config with a missing required key" {
  write_conf_raw <<'EOF'
TIMES="18:00,18:30,18:45,18:50"
WEEKDAYS="1,2,3,4,5,6,7"
KILL_GRACE="10"
EOF
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"LEVEL"* ]]
  [[ "$output" != *"stage="* ]]
}

# 時刻が早い順でなければ拒否する（段階が入れ替わったまま走らない）
@test "conf: rejects TIMES that are not in ascending order" {
  write_conf_file 'TIMES="18:50,18:30,18:45,18:00"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"config invalid"* ]]
}

# HH:MM でない時刻は拒否する
@test "conf: rejects a malformed time" {
  write_conf_file 'TIMES="18:00,18:30,18:45,25:99"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"config invalid"* ]]
}

# 知らないレベルは拒否する
@test "conf: rejects an unknown LEVEL" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="destroy"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"LEVEL"* ]]
}

# 構文エラーのある conf は「既定値で動く」に化けない
@test "conf: a syntax error does not silently fall back to defaults" {
  write_conf_raw <<'EOF'
TIMES="20:00,20:30,20:45,20:50
WEEKDAYS="1,2,3,4,5"
EOF
  run run_at 1130
  [ "$status" -ne 0 ]
  [[ "$output" == *"config invalid"* ]]
  [[ "$output" != *"stage="* ]]
}

# 壊れた conf では plist を出力しない（空 plist で差し替えない）
@test "conf: plist refuses to emit for a broken config" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run bash "$SCRIPT" plist
  [ "$status" -ne 0 ]
  [[ "$output" != *"<plist"* ]]
}

# 壊れた conf でも status は落ちずに理由を見せる
@test "conf: status still reports when the config is broken" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run bash "$SCRIPT" status
  [[ "$output" == *"設定エラー"* ]]
  [[ "$output" == *"TIMES"* ]]
}

# 壊れた conf では dryrun off を通さない。
# ドライラン旗を消してから死ぬと「本番に切り替えたのに何も起きない」になる。
@test "conf: dryrun off keeps the flag while the config is broken" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  touch "$SANDBOX/etc/dryrun"
  run as_root bash "$SCRIPT" dryrun off
  [ "$status" -ne 0 ]
  [ -f "$SANDBOX/etc/dryrun" ]   # 消されていないこと
}

# --- 止める・やめる -----------------------------------------------------
# 非常停止の経路。ここが効かないと逃げ場が無くなるので、必ず自動で見る。

# ドライラン旗のファイルを置くだけで強制終了は起きない。
# スクリプトを一切呼ばずに（sudo touch だけで）止められる経路。
@test "killswitch: the dryrun flag file alone stops the shutdown" {
  touch "$SANDBOX/etc/dryrun"
  # ENDDAYD_DRY_RUN は渡さない。判定材料はファイルの存在だけ
  run env ENDDAYD_FORCE_MIN=1130 bash "$SCRIPT" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would execute"* ]]
  [[ "$output" == *"[DRY]"* ]]
}

# uninstall は本体・plist・旗を消し、設定とログは残す
@test "uninstall: removes the daemon files but keeps the config" {
  mkdir -p "$SANDBOX/installed"
  : >"$SANDBOX/installed/enddayd.sh"
  : >"$SANDBOX/installed/local.enddayd.plist"
  touch "$SANDBOX/etc/dryrun"
  date +%F >"$SANDBOX/etc/skip"
  echo "log line" >"$SANDBOX/enddayd.log"

  run as_root bash "$SCRIPT" uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/installed/enddayd.sh" ]
  [ ! -f "$SANDBOX/installed/local.enddayd.plist" ]
  [ ! -f "$SANDBOX/etc/dryrun" ]
  [ ! -f "$SANDBOX/etc/skip" ]
  [ -f "$SANDBOX/etc/conf" ]        # 設定は残る
  [ -f "$SANDBOX/enddayd.log" ]     # ログも残る
}

# --- ソースの決まりごと -------------------------------------------------

# macOS の bash 3.2 はバイト単位で変数名を読むため、"$BYPASS）" のように
# 変数の直後に全角文字を置くと、その文字まで変数名の一部として食われて
# 実行時に unbound variable で落ちる。shellcheck も bash -n も見つけられず、
# 対話の途中まで進んで初めて分かる。波括弧で囲めば起きない。
@test "lint: no unbraced variable is followed by a multibyte character" {
  run env LC_ALL=C grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$BATS_TEST_DIRNAME/../enddayd.sh"
  [ "$status" -eq 1 ]   # grep の 1 = 該当なし（2 はエラーなので通さない）
  [ -z "$output" ]
}

# root で走るので launchctl は必ず /bin/launchctl と絶対パスで呼ぶ。PATH 経由に
# すると差し替えられる余地が残る。テストのサンドボックスも /bin/launchctl を
# 目印にスタブへ置換しているので、素の launchctl は本物を叩いてしまう。
# 呼び出しを列挙して確かめると足し忘れを見落とすため、全出現を走査して
# 許可した形（/bin/launchctl と、利用者が打つ手順の sudo launchctl）を
# 取り除いた残りが 0 であることを見る。
@test "lint: launchctl is always invoked by absolute path" {
  local hits
  hits=$(env LC_ALL=C sed \
      -e 's#/bin/launchctl##g' \
      -e 's#sudo launchctl##g' \
      "$BATS_TEST_DIRNAME/../enddayd.sh" | grep -n 'launchctl' || true)
  [ -z "$hits" ] || { echo "$hits"; false; }
}

# --- stage / rehearsal の引数 -------------------------------------------

# 知らないステージ名はそこで止まる。
# コマンド置換の中の失敗を見落とすと、時刻指定が空のまま現在時刻で走る。
@test "stage command: an unknown stage name stops the command" {
  run as_root bash "$SCRIPT" stage bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"notice / warn / final / enforce"* ]]
  [[ "$output" != *"out of window"* ]]
  [[ "$output" != *"stage="* ]]
}
