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
  contains "$output" "out of window"
}

# 18:00 は予告
@test "stage: 18:00 is notice" {
  run run_at 1080
  contains "$output" "stage=notice"
}

# 18:29 はまだ予告の範囲
@test "stage: 18:29 is still notice" {
  run run_at 1109
  contains "$output" "stage=notice"
}

# 18:30 は警告
@test "stage: 18:30 is warn" {
  run run_at 1110
  contains "$output" "stage=warn"
}

# 18:45 は最終通告
@test "stage: 18:45 is final" {
  run run_at 1125
  contains "$output" "stage=final"
}

# 18:50 は強制終了
@test "stage: 18:50 is enforce" {
  run run_at 1130
  contains "$output" "stage=enforce"
}

# 猶予内（19:00）はまだ強制終了する
@test "stage: 19:00 is still enforce within grace" {
  run run_at 1140
  contains "$output" "stage=enforce"
}

# 猶予を過ぎたら（19:01）何もしない
@test "stage: 19:01 is past the grace window" {
  run run_at 1141
  contains "$output" "out of window"
}

# 猶予分数は設定で変えられる
@test "stage: KILL_GRACE shrinks the enforce window" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="0"'
  run run_at 1130
  contains "$output" "stage=enforce"
  run run_at 1131
  contains "$output" "out of window"
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
  contains "$output" "not a scheduled weekday"
}

# 対象の曜日なら曜日判定を通過する
@test "weekday: passes the check on a scheduled weekday" {
  local today
  today=$(date +%u)
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$today\"" 'LEVEL="normal"'
  run env ENDDAYD_DRY_RUN=1 bash "$SCRIPT" run
  not_contains "$output" "not a scheduled weekday"
}

# ステージ強制指定は曜日判定を迂回する（リハーサル用）
@test "weekday: forced stage bypasses the weekday check" {
  local today other
  today=$(date +%u)
  other=$(( today % 7 + 1 ))
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' "WEEKDAYS=\"$other\"" 'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  contains "$output" "stage=enforce"
}

# --- 当日スキップ -------------------------------------------------------

# 当日日付のスキップファイルがあれば止まる
@test "bypass: today's date stops the run" {
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  contains "$output" "bypass file for today"
}

# 別の日付のスキップファイルは効かない
@test "bypass: another date does not stop the run" {
  echo "2000-01-01" >"$SANDBOX/etc/skip"
  run run_at 1130
  contains "$output" "stage=enforce"
}

# ALLOW_BYPASS=0 ならスキップファイルを無視する
@test "bypass: ALLOW_BYPASS=0 ignores the skip file" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'ALLOW_BYPASS="0"' 'KILL_GRACE="10"'
  date +%F >"$SANDBOX/etc/skip"
  run run_at 1130
  contains "$output" "stage=enforce"
}

# --- レベル -------------------------------------------------------------

# レベルがログに残る
@test "level: each level is recorded in the log" {
  for lv in notify soft normal hard; do
    write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                    "LEVEL=\"$lv\"" 'KILL_GRACE="10"'
    run run_at 1130
    contains "$output" "level=$lv"
  done
}

# ドライラン中は実際の終了処理に進まない
@test "level: dry run never reaches the real shutdown" {
  run run_at 1130
  contains "$output" "would execute"
}

# --- 本番モードの到達記録 -----------------------------------------------
#
# 導入しても「本当に効くのか」は一度落ちるまで分からない。本番で enforce
# まで来たことをログに残し、status がそれを見せる。到達していれば、
# 少なくとも経路は生きていると分かる。

# 本番で enforce まで来たら記録が残る（notify は電源を落とさないので安全）
@test "reached: a production enforce is recorded in the log" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="notify"' 'KILL_GRACE="10"'
  run_at_live 1130
  contains "$(log_text)" "enforce reached level=notify"
}

# ドライランは到達として記録しない。記録があるのに落ちない状態を作らない
@test "reached: a dry run is not recorded as a production enforce" {
  run run_at 1130
  not_contains "$(log_text)" "enforce reached"
}

# status は最後に到達した日時を出す。
# 判定はその1行に絞る。output 全体を見ると status が末尾に出すログ本文に
# 当たってしまい、表示が空でも通る（何も検証していないテストになる）。
@test "reached: status reports the last production enforce" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="notify"' 'KILL_GRACE="10"'
  run_at_live 1130
  run bash "$SCRIPT" status
  local line
  line=$(echo "$output" | grep '本番到達')
  contains "$line" "level=notify"
  not_contains "$line" "まだありません"
  not_contains "$line" "enforce reached"   # 表示用に整形されている
}

# 一度も到達していなければ、そう言う（空欄にして分からなくしない）
@test "reached: status says so when nothing has reached enforce" {
  run bash "$SCRIPT" status
  local line
  line=$(echo "$output" | grep '本番到達')
  contains "$line" "まだありません"
}

# ドライランの到達は本番の到達として数えない
@test "reached: status ignores a dry run enforce" {
  run_at 1130
  run bash "$SCRIPT" status
  local line
  line=$(echo "$output" | grep '本番到達')
  contains "$line" "まだありません"
}

# 本番の normal は shutdown まで到達する。テストではスタブが受け止める
# （置換に失敗していれば setup_sandbox が先に止める）
@test "reached: production normal invokes shutdown" {
  run_at_live 1130
  contains "$(shutdown_calls)" "-h now"
}

# --- 警告ステージ -------------------------------------------------------

# ログアウト試行が有効なら起動中アプリを記録する
@test "warn: records running apps when logout is enabled" {
  run run_at 1110
  contains "$output" "running apps"
}

# LOGOUT_ATTEMPT=0 ならログアウトを試みない
@test "warn: LOGOUT_ATTEMPT=0 skips the logout attempt" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'LOGOUT_ATTEMPT="0"'
  run run_at 1110
  contains "$output" "logout attempt disabled"
}

# --- 自動化の許可 -------------------------------------------------------
#
# 警告段階のログアウト試行は macOS の「自動化」の許可を要求する。許可が
# 無いと毎回失敗するが、設計上そこで止まらないのでログを読まないと
# 気づけない。リハーサル（ドライラン）の時点で成否を出す。

# 許可があるときは、到達できたことと起動中アプリの両方を出す
@test "automation: dry run reports that System Events is reachable" {
  run run_at 1110
  contains "$output" "automation ok"
  contains "$output" "running apps"
  not_contains "$output" "automation denied"
}

# 許可が無いときは、空の一覧ではなく拒否されたことと直し方を出す
@test "automation: dry run reports a denial with how to grant it" {
  deny_automation
  run run_at 1110
  contains "$output" "automation denied"
  contains "$output" "自動化"
  not_contains "$output" "automation ok"
  not_contains "$output" "running apps"
}

# 本番でログアウトに失敗したとき、許可が無いのかアプリが断ったのかを分ける。
# 「logout request failed」だけでは、設定の問題なのかその日の事情なのかが
# 読み取れず、毎日失敗していても同じ行が並ぶだけになる。
@test "automation: production tells a denial apart from an app refusal" {
  deny_automation
  run_at_live 1110
  contains "$(log_text)" "automation denied"
  not_contains "$(log_text)" "アプリが拒否"
}

# 許可があってログアウトが通れば、拒否の行は出ない
@test "automation: production records a successful logout request" {
  run_at_live 1110
  contains "$(log_text)" "logout requested"
  not_contains "$(log_text)" "automation denied"
}

# --- 時刻の設定 ---------------------------------------------------------

# 設定した時刻に追従する
@test "times: follows the configured schedule" {
  write_conf_file 'TIMES="09:00,09:30,09:45,09:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 540
  contains "$output" "stage=notice"
  run run_at 1130
  contains "$output" "out of window"
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
  contains "$output" "<string>run</string>"
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
  contains "$output" "config invalid"
  not_contains "$output" "out of window"
  not_contains "$output" "stage="
}

# 拒否した理由はログファイルに残る（status が見せるのは $LOG だけ）
@test "conf: the rejection reason is written to the log file" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  contains "$(log_text)" "config invalid"
  contains "$(log_text)" "TIMES"
}

# 曜日が空なら拒否する
@test "conf: rejects an empty WEEKDAYS" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS=""' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "config invalid"
  contains "$output" "WEEKDAYS"
}

# 猶予が数値でなければ拒否する
@test "conf: rejects a non-numeric KILL_GRACE" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="ten"'
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "KILL_GRACE"
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
  contains "$output" "LEVEL"
  not_contains "$output" "stage="
}

# 時刻が早い順でなければ拒否する（段階が入れ替わったまま走らない）
@test "conf: rejects TIMES that are not in ascending order" {
  write_conf_file 'TIMES="18:50,18:30,18:45,18:00"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "config invalid"
}

# HH:MM でない時刻は拒否する
@test "conf: rejects a malformed time" {
  write_conf_file 'TIMES="18:00,18:30,18:45,25:99"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "config invalid"
}

# 知らないレベルは拒否する
@test "conf: rejects an unknown LEVEL" {
  write_conf_file 'TIMES="18:00,18:30,18:45,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="destroy"' 'KILL_GRACE="10"'
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "LEVEL"
}

# 構文エラーのある conf は「既定値で動く」に化けない
@test "conf: a syntax error does not silently fall back to defaults" {
  write_conf_raw <<'EOF'
TIMES="20:00,20:30,20:45,20:50
WEEKDAYS="1,2,3,4,5"
EOF
  run run_at 1130
  [ "$status" -ne 0 ]
  contains "$output" "config invalid"
  not_contains "$output" "stage="
}

# 壊れた conf では plist を出力しない（空 plist で差し替えない）
@test "conf: plist refuses to emit for a broken config" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run bash "$SCRIPT" plist
  [ "$status" -ne 0 ]
  not_contains "$output" "<plist"
}

# 壊れた conf でも status は落ちずに理由を見せる
@test "conf: status still reports when the config is broken" {
  write_conf_file 'TIMES="18:00,18:30,18:50"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run bash "$SCRIPT" status
  contains "$output" "設定エラー"
  contains "$output" "TIMES"
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
  contains "$output" "would execute"
  contains "$output" "[DRY]"
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

# --- 導入 ---------------------------------------------------------------
#
# install(1) はサンドボックスではスタブなので、本物が通ることの担保には
# ならない。ここで見るのは「導入済みかどうかでモードをどう扱うか」の分岐。

# 新規導入は必ずドライランから始まる
@test "install: a fresh install starts in dry run" {
  run as_root_installable bash "$SCRIPT" install
  [ "$status" -eq 0 ]
  contains "$output" "導入しました"
  [ -f "$SANDBOX/etc/dryrun" ]
}

# 入れ直しても本番のままにする。更新のたびに黙ってドライランへ戻ると、
# 効かなくなったことに気づけない（このツールで一番まずい壊れ方）。
@test "install: reinstalling keeps production mode" {
  as_root_installable bash "$SCRIPT" install
  rm -f "$SANDBOX/etc/dryrun"            # 本番へ切り替えた状態にする
  run as_root_installable bash "$SCRIPT" install
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/etc/dryrun" ]
  contains "$output" "本番のまま"
}

# ドライランで入れ直したらドライランのまま（表示も現状を言う）
@test "install: reinstalling keeps dry run mode" {
  as_root_installable bash "$SCRIPT" install
  run as_root_installable bash "$SCRIPT" install
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/etc/dryrun" ]
  contains "$output" "ドライランのまま"
}

# --- 有効だが効き方が違う設定 -------------------------------------------
#
# 拒否はしない。拒否するとその日から強制終了ごと止まってしまい、
# 実害のほうが大きい。走らせたうえで、書いたとおりには効かないと伝える。

# 猶予が日をまたぐ設定は、走るが注意を出す
@test "warning: a grace crossing midnight is reported but still runs" {
  write_conf_file 'TIMES="23:00,23:30,23:45,23:55"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run run_at 1435
  [ "$status" -eq 0 ]
  contains "$output" "stage=enforce"
  contains "$output" "config warning"
  contains "$output" "23:59"
}

# 注意は config の表示にも出る（ログを見なくても分かるように）
@test "warning: config shows the grace that actually applies" {
  write_conf_file 'TIMES="23:00,23:30,23:45,23:55"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="10"'
  run bash "$SCRIPT" config
  contains "$output" "注意"
  contains "$output" "4分"
}

# ちょうど 23:59 に収まる設定には出さない
@test "warning: a grace ending at 23:59 is not reported" {
  write_conf_file 'TIMES="23:00,23:30,23:45,23:55"' 'WEEKDAYS="1,2,3,4,5,6,7"' \
                  'LEVEL="normal"' 'KILL_GRACE="4"'
  run bash "$SCRIPT" config
  not_contains "$output" "注意"
}

# 通常の設定には出さない（毎回出ると読まれなくなる）
@test "warning: an ordinary schedule is not reported" {
  run run_at 1130
  not_contains "$output" "config warning"
}

# --- ログのローテーション -----------------------------------------------

# 導入時に newsyslog の設定を置く。ログは追記のみで放置すると伸び続ける
@test "newsyslog: install places a rotation config" {
  run as_root_installable bash "$SCRIPT" install
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/etc/newsyslog.d/enddayd.conf" ]
  contains "$(cat "$SANDBOX/etc/newsyslog.d/enddayd.conf")" "enddayd.log"
  contains "$(cat "$SANDBOX/etc/newsyslog.d/enddayd.conf")" "enddayd.err.log"
}

# 削除時に消す。残すと存在しないログを回そうとする設定が居座る
@test "newsyslog: uninstall removes the rotation config" {
  as_root_installable bash "$SCRIPT" install
  run as_root bash "$SCRIPT" uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/etc/newsyslog.d/enddayd.conf" ]
}

# 置けなくても導入は止めない。ローテーションが無くても終業は動く
@test "newsyslog: a failure to write it does not stop the install" {
  : >"$SANDBOX/etc/newsyslog.d"        # ディレクトリの場所をファイルで塞ぐ
  run as_root_installable bash "$SCRIPT" install
  [ "$status" -eq 0 ]
  contains "$output" "導入しました"
  [ ! -f "$SANDBOX/etc/newsyslog.d/enddayd.conf" ]
}

# --- GUI が無いとき -----------------------------------------------------

# アラートを出せなかったことをログに残す。
# 残さないと「出したつもり」と「出せなかった」が区別できない。
@test "alert: giving up without a gui user is recorded" {
  cat >"$SANDBOX/bin/stat" <<'EOF'
#!/bin/bash
echo "root"
EOF
  chmod +x "$SANDBOX/bin/stat"
  write_conf_raw <<'EOF'
TIMES="18:00,18:30,18:45"
WEEKDAYS="1,2,3,4,5,6,7"
LEVEL="normal"
EOF
  run run_at 1130
  contains "$output" "alert skipped (no gui user)"
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
# 表明は contains / not_contains で書く。素の二重角括弧は bash 3.2 だと
# 失敗しても errexit を発動せず、最後の1行以外が素通りする（helper.bash 参照）。
# 正しい書き方を列挙して確かめると新しいテストの書き漏れを見落とすので、
# 使ってはいけない形が1つも無いことを走査する。コメント行は説明のために
# 書けるよう除く。
@test "lint: expectations never use a bare double bracket" {
  local hits
  hits=$(grep -nE '\[\[' \
           "$BATS_TEST_DIRNAME/enddayd.bats" \
           "$BATS_TEST_DIRNAME/helper.bash" \
         | grep -vE ':[0-9]+: *#' || true)
  [ -z "$hits" ] || { echo "$hits"; false; }
}

# 途中の表明が実際に止めることを見る。bash 3.2 は [[ ]] の失敗で errexit を
# 発動しないので、素の [[ ]] で書いた表明は最後の1行以外が素通りする。
# contains / not_contains は通常の関数呼び出しなので止まる。この番人が
# 死ぬと、このファイル全体が「最後の1行しか見ていない」状態に戻る。
@test "harness: a failed expectation in the middle stops the test" {
  run bash -c "
    set -e
    source '$BATS_TEST_DIRNAME/helper.bash'
    contains 'abc' 'zzz' 2>/dev/null
    echo REACHED
  "
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  run bash -c "
    set -e
    source '$BATS_TEST_DIRNAME/helper.bash'
    not_contains 'abc' 'abc' 2>/dev/null
    echo REACHED
  "
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# 本番モードの経路をテストする以上、サンドボックスに本物の shutdown が
# 残っていたら実行中のマシンが落ちる。setup_sandbox が置換の失敗で止まる
# ようにしてあるが、その番人が生きていること自体を1件として見せる。
@test "sandbox: the real shutdown path is never left in the copy" {
  run grep -c '/sbin/shutdown' "$SCRIPT"
  [ "$output" = "0" ]
}

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
  contains "$output" "notice / warn / final / enforce"
  not_contains "$output" "out of window"
  not_contains "$output" "stage="
}
