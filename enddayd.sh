#!/bin/bash
#
# enddayd.sh — 平日の定時終業を強制する（macOS 専用・自己完結型）
#
#   sudo ./enddayd.sh setup            対話的に設定して導入
#   sudo ./enddayd.sh install          既定値のまま導入
#   sudo ./enddayd.sh config           現在の設定を表示
#   sudo ./enddayd.sh dryrun on|off    ドライランの切り替え
#   sudo ./enddayd.sh status           状態と直近のログ
#   sudo ./enddayd.sh rehearsal [秒]   全段階を圧縮して今すぐ確認
#   sudo ./enddayd.sh stage <名前>     単一ステージだけ確認
#   sudo ./enddayd.sh log              ログを追う
#   sudo ./enddayd.sh uninstall        削除
#   sudo ./enddayd.sh run              LaunchDaemon から呼ばれる本体
#
# 既定のスケジュール（月〜金）
#   18:00  終了準備のアラート
#   18:30  警告 + ログアウト試行
#   18:45  最終通告
#   18:50  強制終了（レベルに応じて挙動が変わる）
#
set -uo pipefail

# ------------------------------------------------------------- パス ---

LABEL=local.enddayd
BIN=/usr/local/bin/enddayd.sh
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CONF=/etc/enddayd.conf
LOG=/var/log/enddayd.log
BYPASS=/etc/enddayd.skip
DRYFLAG=/etc/enddayd.dryrun

GRACE_SOUND=/System/Library/Sounds/Sosumi.aiff
FINAL_SOUND=/System/Library/Sounds/Basso.aiff

# --------------------------------------------------------- 既定設定 ---
# /etc/enddayd.conf があれば上書きされる。setup サブコマンドが書き出す。

TIMES="18:00,18:30,18:45,18:50"   # 予告,警告,最終通告,強制終了
WEEKDAYS="1,2,3,4,5"              # 1=月 … 7=日
LEVEL="normal"                    # notify | soft | normal | hard
LOGOUT_ATTEMPT="1"                # 警告時にログアウトを試みるか
ALLOW_BYPASS="1"                  # 当日スキップを許すか
KILL_GRACE="10"                   # 最終ステージを受け付ける猶予（分）

# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

IFS=',' read -r -a T_ARR <<<"$TIMES"
IFS=',' read -r -a W_ARR <<<"$WEEKDAYS"

# ------------------------------------------------------- 共通ヘルパ ---

DRY=0
if [ -f "$DRYFLAG" ] || [ "${ENDDAYD_DRY_RUN:-0}" = "1" ]; then DRY=1; fi

log() {
  local tag=""
  [ "$DRY" = "1" ] && tag="[DRY] "
  echo "$(date '+%F %T') ${tag}$*" >>"$LOG" 2>/dev/null
  [ "$DRY" = "1" ] && echo "$(date '+%F %T') ${tag}$*"
  return 0
}

mark() { if [ "$DRY" = "1" ]; then echo "【ドライラン】$1"; else echo "$1"; fi; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then echo "sudo で実行してください" >&2; exit 1; fi
}

to_min() { local h="${1%%:*}" m="${1##*:}"; echo $((10#$h * 60 + 10#$m)); }

valid_time() { echo "$1" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; }

dow_name() {
  case "$1" in 1) echo 月;; 2) echo 火;; 3) echo 水;; 4) echo 木;; 5) echo 金;;
               6) echo 土;; 7) echo 日;; *) echo "?";; esac
}

level_label() {
  case "$1" in
    notify) echo "notify — 通知のみ。電源は落とさない" ;;
    soft)   echo "soft   — アプリに終了を依頼。未保存があれば止まる" ;;
    normal) echo "normal — root から shutdown。アプリの拒否権なし" ;;
    hard)   echo "hard   — セッションを強制的に畳んでから shutdown" ;;
    *)      echo "$1" ;;
  esac
}

stage_min() {
  case "$1" in
    notice) to_min "${T_ARR[0]}" ;;
    warn)   to_min "${T_ARR[1]}" ;;
    final)  to_min "${T_ARR[2]}" ;;
    enforce) to_min "${T_ARR[3]}" ;;
    *) echo "ステージ名は notice / warn / final / enforce のいずれかです" >&2; exit 1 ;;
  esac
}

# ---------------------------------------------------------- 本体 run ---

cmd_run() {
  local FORCE_MIN="${ENDDAYD_FORCE_MIN:-}"

  # 設定された曜日のみ
  local DOW hit=0 w
  DOW=$(date +%u)
  for w in "${W_ARR[@]}"; do [ "$w" = "$DOW" ] && hit=1; done
  if [ -z "$FORCE_MIN" ] && [ "$hit" = "0" ]; then
    log "skip: not a scheduled weekday"; exit 0
  fi

  # 当日日付が書かれた bypass ファイル
  if [ "$ALLOW_BYPASS" = "1" ] && [ -f "$BYPASS" ] \
     && [ "$(cat "$BYPASS" 2>/dev/null)" = "$(date +%F)" ]; then
    log "skip: bypass file for today"; exit 0
  fi

  local CONSOLE_USER CONSOLE_UID
  CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
  if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    log "skip: no gui user"; exit 0
  fi
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER")

  asuser() { /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"; }
  play()   { [ -f "$1" ] && asuser /usr/bin/afplay "$1" >/dev/null 2>&1 & }
  # display alert は osascript 自身の UI なので通知許可の設定に左右されない。
  alert() {
    asuser /usr/bin/osascript \
      -e "display alert \"${1}\" message \"${2}\" as critical giving up after ${3}" \
      >/dev/null 2>&1
  }

  # ステージは実行時の時計で決める。スリープ復帰後の遅延実行で誤爆しない。
  local MIN
  if [ -n "$FORCE_MIN" ]; then MIN="$FORCE_MIN"
  else MIN=$((10#$(date +%H) * 60 + 10#$(date +%M))); fi

  local M0 M1 M2 M3 STAGE
  M0=$(to_min "${T_ARR[0]}"); M1=$(to_min "${T_ARR[1]}")
  M2=$(to_min "${T_ARR[2]}"); M3=$(to_min "${T_ARR[3]}")

  if   [ "$MIN" -ge "$M0" ] && [ "$MIN" -lt "$M1" ]; then STAGE=notice
  elif [ "$MIN" -ge "$M1" ] && [ "$MIN" -lt "$M2" ]; then STAGE=warn
  elif [ "$MIN" -ge "$M2" ] && [ "$MIN" -lt "$M3" ]; then STAGE=final
  elif [ "$MIN" -ge "$M3" ] && [ "$MIN" -le $((M3 + KILL_GRACE)) ]; then STAGE=enforce
  else log "skip: out of window (min=$MIN)"; exit 0; fi

  log "stage=$STAGE level=$LEVEL user=$CONSOLE_USER"

  case "$STAGE" in

    notice)
      play "$GRACE_SOUND"
      alert "$(mark "${T_ARR[0]} — 終業時刻です")" \
            "作業を切り上げる準備を始めてください。${T_ARR[3]} に終了します。" 30
      log "notice shown"
      ;;

    warn)
      play "$GRACE_SOUND"
      alert "$(mark "${T_ARR[1]} — ここで終わりです")" \
            "コミット・保存を済ませてください。${T_ARR[3]} に強制的に終了します。" 45
      if [ "$LOGOUT_ATTEMPT" != "1" ]; then
        log "logout attempt disabled"
      elif [ "$DRY" = "1" ]; then
        log "would request logout"
        log "running apps: $(asuser /usr/bin/osascript -e \
          'tell application "System Events" to get name of every application process whose background only is false' \
          2>/dev/null)"
      else
        # ここは意図的に「止まってよい」経路。拒否されたら保存の機会になる。
        if asuser /usr/bin/osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1; then
          log "logout requested"
        else
          log "logout request failed (自動化の許可 or アプリが拒否)"
        fi
      fi
      ;;

    final)
      play "$FINAL_SOUND"
      alert "$(mark "${T_ARR[2]} — 最終通告")" \
            "まもなく終了します（レベル: ${LEVEL}）。保存していない変更は失われます。" 60
      log "final notice shown"
      ;;

    enforce)
      play "$FINAL_SOUND"
      if [ "$DRY" = "1" ]; then
        log "would execute level=$LEVEL"
        alert "$(mark "${T_ARR[3]} — ここで終了します")" \
              "本番ならこの時点で終了していました（レベル: ${LEVEL}）。まだ動いているのはドライラン中だからです。" 60
        exit 0
      fi
      case "$LEVEL" in
        notify)
          log "level=notify: 通知のみ"
          alert "${T_ARR[3]} — 終業時刻です" "設定はレベル notify なので電源は落としません。" 60
          ;;
        soft)
          log "level=soft: アプリに終了を依頼"
          asuser /usr/bin/osascript -e 'tell application "System Events" to shut down' >/dev/null 2>&1 \
            || log "soft shutdown が拒否された"
          ;;
        normal)
          log "level=normal: shutdown -h now"
          sleep 2
          /sbin/shutdown -h now
          ;;
        hard)
          log "level=hard: セッションを畳んでから shutdown"
          /bin/launchctl bootout "gui/${CONSOLE_UID}" >/dev/null 2>&1
          sleep 3
          /sbin/shutdown -h now
          ;;
        *)
          log "unknown level=$LEVEL, normal として扱う"
          sleep 2
          /sbin/shutdown -h now
          ;;
      esac
      ;;
  esac
}

# ------------------------------------------------------------ plist ---

gen_plist() {
  local entries="" d t h m
  for d in "${W_ARR[@]}"; do
    for t in "${T_ARR[@]}"; do
      h=$((10#${t%%:*})); m=$((10#${t##*:}))
      entries+="    <dict><key>Weekday</key><integer>${d}</integer>"
      entries+="<key>Hour</key><integer>${h}</integer>"
      entries+="<key>Minute</key><integer>${m}</integer></dict>"$'\n'
    done
  done

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
    <string>run</string>
  </array>

  <key>StartCalendarInterval</key>
  <array>
${entries}  </array>

  <key>StandardErrorPath</key>
  <string>/var/log/enddayd.err.log</string>
</dict>
</plist>
EOF
}

write_conf() {
  cat >"$CONF" <<EOF
# enddayd 設定ファイル。手で編集したら sudo $BIN reload を実行してください。
TIMES="$TIMES"
WEEKDAYS="$WEEKDAYS"
LEVEL="$LEVEL"
LOGOUT_ATTEMPT="$LOGOUT_ATTEMPT"
ALLOW_BYPASS="$ALLOW_BYPASS"
KILL_GRACE="$KILL_GRACE"
EOF
  chmod 644 "$CONF"; chown root:wheel "$CONF"
}

load_daemon() {
  gen_plist >"$PLIST"
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"
  launchctl bootout system "$PLIST" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  launchctl enable "system/${LABEL}"
}

# -------------------------------------------------------- 対話セットアップ ---

ask() {  # ask "質問" "既定値" → 変数 REPLY_VAL
  local q="$1" def="$2" ans
  printf "%s [%s]: " "$q" "$def" >&2
  read -r ans
  REPLY_VAL="${ans:-$def}"
}

cmd_setup() {
  need_root
  if [ ! -t 0 ]; then echo "対話セットアップには端末が必要です" >&2; exit 1; fi

  echo "=============================================="
  echo " enddayd 設定"
  echo "=============================================="
  echo

  # --- 曜日 ---
  echo "【対象の曜日】1=月 2=火 3=水 4=木 5=金 6=土 7=日（カンマ区切り）"
  while :; do
    ask "  曜日" "$WEEKDAYS"
    if echo "$REPLY_VAL" | grep -Eq '^[1-7](,[1-7])*$'; then WEEKDAYS="$REPLY_VAL"; break; fi
    echo "  → 1〜7 をカンマ区切りで入力してください" >&2
  done
  IFS=',' read -r -a W_ARR <<<"$WEEKDAYS"
  echo

  # --- 時刻 ---
  echo "【時刻】4段階を早い順に指定します（HH:MM）"
  local labels=("予告（作業を切り上げる合図）" "警告（実質の締切）" "最終通告" "強制終了")
  local defaults=("${T_ARR[0]}" "${T_ARR[1]}" "${T_ARR[2]}" "${T_ARR[3]}")
  local new=() i prev=-1 cur
  for i in 0 1 2 3; do
    while :; do
      ask "  ${labels[$i]}" "${defaults[$i]}"
      if ! valid_time "$REPLY_VAL"; then echo "  → HH:MM で入力してください" >&2; continue; fi
      cur=$(to_min "$REPLY_VAL")
      if [ "$cur" -le "$prev" ]; then echo "  → 前の段階より後の時刻にしてください" >&2; continue; fi
      new+=("$REPLY_VAL"); prev="$cur"; break
    done
  done
  TIMES="${new[0]},${new[1]},${new[2]},${new[3]}"
  IFS=',' read -r -a T_ARR <<<"$TIMES"
  echo

  # --- 強制レベル ---
  echo "【強制終了のレベル】"
  echo "  1) notify  通知だけ出す。電源は落とさない（まず様子を見たいとき）"
  echo "  2) soft    アプリに終了を依頼する。未保存があれば止まる（回避できる）"
  echo "  3) normal  root から shutdown。アプリの拒否権なし（推奨）"
  echo "  4) hard    セッションを強制的に畳んでから shutdown（未保存は確実に失われる）"
  local defnum=3
  case "$LEVEL" in notify) defnum=1;; soft) defnum=2;; normal) defnum=3;; hard) defnum=4;; esac
  while :; do
    ask "  レベル(1-4)" "$defnum"
    case "$REPLY_VAL" in
      1) LEVEL=notify; break ;;
      2) LEVEL=soft;   break ;;
      3) LEVEL=normal; break ;;
      4) LEVEL=hard
         echo "  ※ hard は編集中のファイルを保存せずに落とします。" >&2
         ask "  それでも hard にしますか (yes/no)" "no"
         [ "$(echo "$REPLY_VAL" | tr '[:upper:]' '[:lower:]')" = "yes" ] && break
         LEVEL=normal; echo "  → normal に戻しました" >&2; break ;;
      *) echo "  → 1〜4 で入力してください" >&2 ;;
    esac
  done
  echo

  # --- 細かい挙動 ---
  ask "警告の段階でログアウトを試みますか (y/n)" "$([ "$LOGOUT_ATTEMPT" = 1 ] && echo y || echo n)"
  [ "$(echo "$REPLY_VAL" | tr '[:upper:]' '[:lower:]')" = "y" ] && LOGOUT_ATTEMPT=1 || LOGOUT_ATTEMPT=0

  ask "当日スキップ（/etc/enddayd.skip）を許しますか (y/n)" "$([ "$ALLOW_BYPASS" = 1 ] && echo y || echo n)"
  [ "$(echo "$REPLY_VAL" | tr '[:upper:]' '[:lower:]')" = "y" ] && ALLOW_BYPASS=1 || ALLOW_BYPASS=0

  ask "最終段階を受け付ける猶予（分）" "$KILL_GRACE"
  echo "$REPLY_VAL" | grep -Eq '^[0-9]+$' && KILL_GRACE="$REPLY_VAL"
  echo

  # --- 確認 ---
  echo "----------------------------------------------"
  cmd_config_body
  echo "----------------------------------------------"
  ask "この内容で導入しますか (yes/no)" "yes"
  if [ "$(echo "$REPLY_VAL" | tr '[:upper:]' '[:lower:]')" != "yes" ]; then
    echo "中止しました。"; exit 0
  fi

  local self
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  install -m 755 -o root -g wheel "$self" "$BIN"
  write_conf
  touch "$DRYFLAG"          # 初回は必ずドライラン
  load_daemon

  echo
  echo "導入しました（ドライラン中：まだ終了しません）"
  ask "いま全段階を通しで確認しますか (y/n)" "y"
  if [ "$(echo "$REPLY_VAL" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
    ENDDAYD_DRY_RUN=1 cmd_rehearsal 5
  fi
  echo
  echo "本番に切り替える: sudo $BIN dryrun off"
}

# --------------------------------------------------------- サブコマンド ---

cmd_install() {
  need_root
  local self
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  install -m 755 -o root -g wheel "$self" "$BIN"
  [ -f "$CONF" ] || write_conf
  touch "$DRYFLAG"
  load_daemon
  echo "導入しました（ドライラン中：まだ終了しません）"
  echo "  設定を変える: sudo $BIN setup"
  echo "  通しで確認  : sudo $BIN rehearsal"
  echo "  本番に切替  : sudo $BIN dryrun off"
}

cmd_reload() { need_root; load_daemon; echo "設定を読み直しました。"; cmd_config_body; }

cmd_uninstall() {
  need_root
  launchctl bootout system "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" "$BIN" "$DRYFLAG"
  echo "削除しました（設定 $CONF は残しています）。"
}

cmd_dryrun() {
  need_root
  case "${1:-}" in
    on)  touch "$DRYFLAG"; echo "ドライラン: ON（終了処理は実行しません）" ;;
    off) rm -f "$DRYFLAG"; echo "ドライラン: OFF（次回 ${T_ARR[3]} に レベル ${LEVEL} で終了します）" ;;
    *)   echo "usage: sudo $0 dryrun on|off" >&2; exit 1 ;;
  esac
}

cmd_config_body() {
  local d names=""
  for d in "${W_ARR[@]}"; do names="${names}$(dow_name "$d")"; done
  echo "曜日        : $names"
  echo "予告        : ${T_ARR[0]}"
  echo "警告        : ${T_ARR[1]}  （ログアウト試行: $([ "$LOGOUT_ATTEMPT" = 1 ] && echo あり || echo なし)）"
  echo "最終通告    : ${T_ARR[2]}"
  echo "強制終了    : ${T_ARR[3]}  （猶予 ${KILL_GRACE}分）"
  echo "レベル      : $(level_label "$LEVEL")"
  echo "当日スキップ: $([ "$ALLOW_BYPASS" = 1 ] && echo 許可 || echo 不可)"
  echo "モード      : $([ -f "$DRYFLAG" ] && echo ドライラン || echo 本番)"
}

cmd_config() { cmd_config_body; echo; echo "設定ファイル: $CONF"; }

cmd_status() {
  cmd_config_body
  if [ -f "$BIN" ]; then echo "スクリプト  : $BIN"; else echo "スクリプト  : 未導入"; fi
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "デーモン    : 登録済み"
  else
    echo "デーモン    : 未登録"
  fi
  [ -f "$BYPASS" ] && echo "スキップ指定: $(cat "$BYPASS")"
  echo "--- 直近のログ ---"
  tail -n 10 "$LOG" 2>/dev/null || echo "(まだありません)"
}

cmd_rehearsal() {
  need_root
  local gap="${1:-20}" s
  echo "全段階を ${gap} 秒間隔で通します。実際には終了しません。中断は Ctrl-C。"
  for s in notice warn final enforce; do
    echo "--- $s ---"
    ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$(stage_min "$s")" bash "$0" run || true
    [ "$s" = "enforce" ] || sleep "$gap"
  done
  echo "リハーサル完了。"
}

cmd_stage() {
  need_root
  ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$(stage_min "${1:-notice}")" bash "$0" run
}

case "${1:-}" in
  run)        cmd_run ;;
  setup)      cmd_setup ;;
  install)    cmd_install ;;
  reload)     cmd_reload ;;
  uninstall)  cmd_uninstall ;;
  config)     cmd_config ;;
  dryrun)     cmd_dryrun "${2:-}" ;;
  status)     cmd_status ;;
  rehearsal)  cmd_rehearsal "${2:-}" ;;
  stage)      cmd_stage "${2:-notice}" ;;
  plist)      gen_plist ;;
  log)        tail -f "$LOG" ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
