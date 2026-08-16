#!/bin/bash
#
# enddayd.sh — 平日の定時終業を強制する（macOS 専用・自己完結型）
#
#   sudo ./enddayd.sh setup            対話的に設定して導入
#   sudo ./enddayd.sh install          既定値のまま導入
#   sudo ./enddayd.sh config           現在の設定を表示
#   sudo ./enddayd.sh reload           設定ファイルを手で編集した後に反映
#   sudo ./enddayd.sh dryrun on|off    ドライランの切り替え
#   sudo ./enddayd.sh today [...]      今日だけの調整（延長・レベル）。翌日は自動で戻る
#   sudo ./enddayd.sh status           状態と直近のログ
#   sudo ./enddayd.sh rehearsal [秒]   全段階を圧縮して今すぐ確認
#   sudo ./enddayd.sh stage <名前>     単一ステージだけ確認
#   sudo ./enddayd.sh plist            生成される plist を表示
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
ERRLOG=/var/log/enddayd.err.log
BYPASS=/etc/enddayd.skip
DRYFLAG=/etc/enddayd.dryrun
NEWSYSLOG=/etc/newsyslog.d/enddayd.conf
TODAY_FILE=/etc/enddayd.today

# 「今日だけ」の延長で選べる分数。
#
# 任意の分数にできない理由: launchd のトリガは plist に固定で書いてある。
# 強制終了を後ろへずらすには、ずらした先にも発火が要る。だから選べる値と
# 受け皿のトリガを1対1で対応させ、gen_plist が両方を出す。
#
# 上限を 120 分にしてあるのは、いくらでも延ばせるなら当日スキップと
# 変わらなくなるため。緩めるための仕組みが、素通しの仕組みになっては困る。
EXTEND_SLOTS="30 60 90 120"

GRACE_SOUND=/System/Library/Sounds/Sosumi.aiff
FINAL_SOUND=/System/Library/Sounds/Basso.aiff

# 強制終了の直前に出すアラートの表示秒数。閉じても中断はされない。
# 「蓋を開けたら何も出ずに電源が落ちた」を避けるためだけのもの。
ENFORCE_ALERT_SEC=10

# --------------------------------------------------------- 既定設定 ---
# /etc/enddayd.conf があれば上書きされる。setup サブコマンドが書き出す。

TIMES="18:00,18:30,18:45,18:50"   # 予告,警告,最終通告,強制終了
WEEKDAYS="1,2,3,4,5"              # 1=月 … 7=日
LEVEL="normal"                    # notify | soft | normal | hard
LOGOUT_ATTEMPT="1"                # 警告時にログアウトを試みるか
ALLOW_BYPASS="1"                  # 当日スキップを許すか
KILL_GRACE="10"                   # 最終ステージを受け付ける猶予（分）

CONF_SYNTAX_ERROR=0
if [ -f "$CONF" ]; then
  # 構文エラーのある conf を素で source すると、代入だけが失敗して
  # 既定値のまま動き続ける（20:00 のつもりが 18:00 になる）。先に弾く。
  if /bin/bash -n "$CONF" 2>/dev/null; then
    # conf が存在する場合はスケジュールの必須項目を空にしてから読む。
    # 項目の欠落を既定値で補うと、利用者の意図と違う時刻で動くため。
    TIMES=""
    WEEKDAYS=""
    LEVEL=""
    # shellcheck source=/dev/null
    . "$CONF"
  else
    CONF_SYNTAX_ERROR=1
  fi
fi

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

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

to_min() { local h="${1%%:*}" m="${1##*:}"; echo $((10#$h * 60 + 10#$m)); }

to_hhmm() { printf '%02d:%02d\n' $(($1 / 60)) $(($1 % 60)); }

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

# ------------------------------------------------- GUI ユーザーへの出力 ---

CONSOLE_USER=""
CONSOLE_UID=""

# GUI にログイン中のユーザーを解決する。いなければ 1 を返す。
resolve_console() {
  CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
  if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then return 1; fi
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null) || return 1
  [ -n "$CONSOLE_UID" ]
}

asuser() { /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"; }

play() { [ -f "$1" ] && asuser /usr/bin/afplay "$1" >/dev/null 2>&1 & }

# display alert は osascript 自身の UI なので通知許可の設定に左右されない。
alert() {
  asuser /usr/bin/osascript \
    -e "display alert \"${1}\" message \"${2}\" as critical giving up after ${3}" \
    >/dev/null 2>&1
}

# GUI ユーザーがいなければ諦める best-effort 版。
# 諦めたことはログに残す。残さないと、ログに「設定が読めません」とあるのに
# 画面には何も出ていない状況で、アラートを出したつもりなのか出せなかったのかが
# 区別できない。
console_alert() {
  if ! resolve_console; then
    log "alert skipped (no gui user): $1"
    return 0
  fi
  alert "$1" "$2" "${3:-30}"
  return 0
}

# 警告段階のログアウト試行は macOS の「自動化」の許可を要求する。許可が
# 無いと毎回失敗するが、設計上そこで止まらないので気づきにくい。
# 副作用のない問い合わせで到達可否だけを確かめる。成功すれば前面アプリの
# 一覧を返すので、ドライランではそれをそのままログに出す。
automation_probe() {
  asuser /usr/bin/osascript -e \
    'tell application "System Events" to get name of every application process whose background only is false' \
    2>/dev/null
}

# --------------------------------------------------------- 設定の検証 ---
# conf は README で手編集を案内している。setup の対話を通らない経路が
# あるので、読み込んだ直後に必ず検証する。壊れた設定のまま走ると
# 「何もしない」が正常なログに見えてしまい、止まったことに気づけない。

CONF_ERRORS=""

# 走ることは走るが、書いたとおりには効かないもの。拒否すると
# その日から強制終了ごと止まってしまうので、伝えるだけにする。
CONF_WARNINGS=""

conf_err() {
  [ -n "$CONF_ERRORS" ] && CONF_ERRORS="${CONF_ERRORS}"$'\n'
  CONF_ERRORS="${CONF_ERRORS}  - $1"
  return 0
}

conf_warn() {
  [ -n "$CONF_WARNINGS" ] && CONF_WARNINGS="${CONF_WARNINGS}"$'\n'
  CONF_WARNINGS="${CONF_WARNINGS}  - $1"
  return 0
}

validate_conf() {
  CONF_ERRORS=""
  CONF_WARNINGS=""

  if [ "$CONF_SYNTAX_ERROR" = "1" ]; then
    conf_err "$CONF に構文エラーがあります（bash -n \"$CONF\" で確認してください）"
    return 1
  fi

  local ta wa i w prev cur
  IFS=',' read -r -a ta <<<"$TIMES"
  IFS=',' read -r -a wa <<<"$WEEKDAYS"

  if [ "${#ta[@]}" -ne 4 ]; then
    conf_err "TIMES は 予告,警告,最終通告,強制終了 の4つが必要です（いま ${#ta[@]} 個）: TIMES=\"$TIMES\""
  else
    prev=-1
    for i in 0 1 2 3; do
      if ! valid_time "${ta[$i]}"; then
        conf_err "TIMES の \"${ta[$i]}\" が HH:MM ではありません: TIMES=\"$TIMES\""
        break
      fi
      cur=$(to_min "${ta[$i]}")
      if [ "$cur" -le "$prev" ]; then
        conf_err "TIMES は早い順に並べてください: TIMES=\"$TIMES\""
        break
      fi
      prev="$cur"
    done
  fi

  if [ "${#wa[@]}" -eq 0 ]; then
    conf_err "WEEKDAYS が空です（1=月 … 7=日 をカンマ区切りで）"
  else
    for w in "${wa[@]}"; do
      case "$w" in
        [1-7]) ;;
        *) conf_err "WEEKDAYS の \"$w\" が 1〜7 ではありません: WEEKDAYS=\"$WEEKDAYS\""; break ;;
      esac
    done
  fi

  case "$LEVEL" in
    notify|soft|normal|hard) ;;
    *) conf_err "LEVEL は notify / soft / normal / hard のいずれかです: LEVEL=\"$LEVEL\"" ;;
  esac

  case "$KILL_GRACE" in
    ''|*[!0-9]*) conf_err "KILL_GRACE は 0 以上の整数（分）です: KILL_GRACE=\"$KILL_GRACE\"" ;;
  esac

  case "$LOGOUT_ATTEMPT" in
    0|1) ;;
    *) conf_err "LOGOUT_ATTEMPT は 0 か 1 です: LOGOUT_ATTEMPT=\"$LOGOUT_ATTEMPT\"" ;;
  esac

  case "$ALLOW_BYPASS" in
    0|1) ;;
    *) conf_err "ALLOW_BYPASS は 0 か 1 です: ALLOW_BYPASS=\"$ALLOW_BYPASS\"" ;;
  esac

  # 妥当な設定に対してだけ注意書きを作る。壊れているなら直すべきは
  # そちらで、警告を重ねても読み手を迷わせるだけ。
  if [ -z "$CONF_ERRORS" ]; then
    local last end_of_day
    last=$(to_min "${ta[3]}")
    end_of_day=$((24 * 60 - 1))
    if [ $((last + KILL_GRACE)) -gt "$end_of_day" ]; then
      conf_warn "猶予が日をまたぎます。${ta[3]} から ${KILL_GRACE}分 は 23:59 で切れるので、実際に受け付けるのは $((end_of_day - last))分 です"
    fi
  fi

  [ -z "$CONF_ERRORS" ]
}

# 検証を通ったときだけ配列に展開する。壊れた設定で ${T_ARR[3]} を
# 触ると set -u で落ち、その落ち方がログに出ないまま握り潰される。
T_ARR=()
W_ARR=()
if validate_conf; then
  IFS=',' read -r -a T_ARR <<<"$TIMES"
  IFS=',' read -r -a W_ARR <<<"$WEEKDAYS"
fi

# 設定が壊れているとき、そのまま進んではいけないコマンドで使う。
require_valid_conf() {
  [ -z "$CONF_ERRORS" ] && return 0
  {
    echo "設定ファイル $CONF に問題があります:"
    echo "$CONF_ERRORS"
    echo "  直したうえで sudo $BIN reload、または sudo $BIN setup をやり直してください"
  } >&2
  return 1
}

# ------------------------------------------------------ 今日だけの調整 ---
#
# 当日スキップと同じく日付印を押す。翌日は日付が合わないので勝手に失効する。
# 「緩めたまま戻し忘れる」が起きない形にしておくのがこのツールの前提。
#
# 延長は強制終了だけを後ろへずらす。予告・警告・最終通告は動かさない。
# 延ばすかどうかは普通、警告を見てから決めるので、先頭を動かすと
# 決める前に決めさせることになる。

TODAY_EXTEND=0
TODAY_LEVEL=""
TODAY_ERROR=""

# /etc/enddayd.today を読む。壊れていても走行は止めない（緩める側の指定なので、
# 無視すれば元の（厳しい）スケジュールで動く）。理由はログに残す。
read_today() {
  TODAY_EXTEND=0
  TODAY_LEVEL=""
  TODAY_ERROR=""
  [ -f "$TODAY_FILE" ] || return 0

  local line key value stamp="" ext="" lv=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      DATE)   stamp="$value" ;;
      EXTEND) ext="$value" ;;
      LEVEL)  lv="$value" ;;
    esac
  done <"$TODAY_FILE"

  if [ "$stamp" != "$(date +%F)" ]; then
    return 0   # 昨日以前のもの。黙って無効（そういう設計）
  fi

  if [ -n "$ext" ]; then
    case " $EXTEND_SLOTS " in
      *" $ext "*) TODAY_EXTEND="$ext" ;;
      *) TODAY_ERROR="EXTEND は $EXTEND_SLOTS のいずれかです: \"$ext\"" ;;
    esac
  fi

  if [ -n "$lv" ]; then
    case "$lv" in
      notify|soft|normal|hard) TODAY_LEVEL="$lv" ;;
      *) TODAY_ERROR="${TODAY_ERROR:+$TODAY_ERROR / }LEVEL は notify / soft / normal / hard のいずれかです: \"$lv\"" ;;
    esac
  fi

  # 日をまたぐ延長は受けない。翌日の曜日判定をどう扱うかが決まっていないので、
  # 中途半端に効かせるより効かせないほうが読みやすい。
  if [ "$TODAY_EXTEND" -gt 0 ] 2>/dev/null; then
    local last
    last=$(to_min "${T_ARR[3]}")
    if [ $((last + TODAY_EXTEND + KILL_GRACE)) -gt $((24 * 60 - 1)) ]; then
      TODAY_ERROR="${TODAY_ERROR:+$TODAY_ERROR / }延長すると日をまたぐので受け付けません（${T_ARR[3]} + ${TODAY_EXTEND}分 + 猶予${KILL_GRACE}分）"
      TODAY_EXTEND=0
    fi
  fi

  [ -n "$TODAY_ERROR" ] && TODAY_EXTEND=0
  return 0
}

# 今日だけの調整を人が読む形で1行にする。無ければ空。
today_summary() {
  local parts=""
  [ "$TODAY_EXTEND" -gt 0 ] 2>/dev/null && parts="強制終了を ${TODAY_EXTEND}分 延長"
  [ -n "$TODAY_LEVEL" ] && parts="${parts:+$parts / }レベルを ${TODAY_LEVEL} に変更"
  echo "$parts"
}

stage_min() {
  case "$1" in
    notice) to_min "${T_ARR[0]}" ;;
    warn)   to_min "${T_ARR[1]}" ;;
    final)  to_min "${T_ARR[2]}" ;;
    enforce) to_min "${T_ARR[3]}" ;;
    *) echo "ステージ名は notice / warn / final / enforce のいずれかです" >&2; return 1 ;;
  esac
}

daemon_loaded() { /bin/launchctl print "system/${LABEL}" >/dev/null 2>&1; }

# ---------------------------------------------------------- 本体 run ---

cmd_run() {
  local FORCE_MIN="${ENDDAYD_FORCE_MIN:-}"

  # 設定が壊れているなら、黙って何もしないのではなく残して知らせる。
  # ここで log に書くのは status が見せるのが $LOG だけだから。
  if [ -n "$CONF_ERRORS" ]; then
    log "config invalid: $(echo "$CONF_ERRORS" | tr '\n' ' ')"
    console_alert "enddayd: 設定が読めません" \
      "$CONF を直してください。直すまで終業は実行されません。" 30
    exit 1
  fi

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

  if ! resolve_console; then
    log "skip: no gui user"; exit 0
  fi

  # ステージは実行時の時計で決める。スリープ復帰後の遅延実行で誤爆しない。
  local MIN
  if [ -n "$FORCE_MIN" ]; then MIN="$FORCE_MIN"
  else MIN=$((10#$(date +%H) * 60 + 10#$(date +%M))); fi

  # 今日だけの調整。壊れていても走行は止めない（緩める側の指定なので、
  # 無視すれば元の厳しいスケジュールで動く）。理由だけ残す。
  read_today
  [ -n "$TODAY_ERROR" ] && log "today override ignored: $TODAY_ERROR"
  [ -n "$TODAY_LEVEL" ] && LEVEL="$TODAY_LEVEL"

  local M0 M1 M2 M3 MK KILL_AT STAGE
  M0=$(to_min "${T_ARR[0]}"); M1=$(to_min "${T_ARR[1]}")
  M2=$(to_min "${T_ARR[2]}"); M3=$(to_min "${T_ARR[3]}")
  MK=$((M3 + TODAY_EXTEND))          # 今日の実際の強制終了時刻
  KILL_AT=$(to_hhmm "$MK")

  # 延長中は、元の強制終了時刻のトリガと途中の受け皿では何もしない。
  # ここで final を出し直すと最終通告が二重に出る。
  if [ "$TODAY_EXTEND" -gt 0 ] && [ "$MIN" -ge "$M3" ] && [ "$MIN" -lt "$MK" ]; then
    log "extended: enforce moved to $KILL_AT (+${TODAY_EXTEND}m)"
    exit 0
  fi

  if   [ "$MIN" -ge "$M0" ] && [ "$MIN" -lt "$M1" ]; then STAGE=notice
  elif [ "$MIN" -ge "$M1" ] && [ "$MIN" -lt "$M2" ]; then STAGE=warn
  elif [ "$MIN" -ge "$M2" ] && [ "$MIN" -lt "$MK" ]; then STAGE=final
  elif [ "$MIN" -ge "$MK" ] && [ "$MIN" -le $((MK + KILL_GRACE)) ]; then STAGE=enforce
  else log "skip: out of window (min=$MIN)"; exit 0; fi

  log "stage=$STAGE level=$LEVEL user=$CONSOLE_USER"

  # 有効だが書いたとおりに効かない設定は、走るたびにログへ残す。
  # status は $LOG しか見せないので、ここに出しておかないと
  # 「なぜ猶予が短いのか」を追う手がかりがどこにも無くなる。
  if [ -n "$CONF_WARNINGS" ]; then
    log "config warning: $(echo "$CONF_WARNINGS" | tr '\n' ' ')"
  fi

  case "$STAGE" in

    notice)
      play "$GRACE_SOUND"
      alert "$(mark "${T_ARR[0]} — 終業時刻です")" \
            "作業を切り上げる準備を始めてください。${KILL_AT} に終了します。" 30
      log "notice shown"
      ;;

    warn)
      play "$GRACE_SOUND"
      alert "$(mark "${T_ARR[1]} — ここで終わりです")" \
            "コミット・保存を済ませてください。${KILL_AT} に強制的に終了します。" 45
      local apps
      if [ "$LOGOUT_ATTEMPT" != "1" ]; then
        log "logout attempt disabled"
      elif [ "$DRY" = "1" ]; then
        log "would request logout"
        # 許可の有無までドライランで見ておかないと、リハーサルが全部通っても
        # 本番のログアウト試行だけが毎回失敗する状態に気づけない。
        if apps=$(automation_probe); then
          log "automation ok: System Events に到達できました"
          log "running apps: $apps"
        else
          log "automation denied: System Events を操作できません（本番のログアウト試行は失敗します）"
          log "許可は システム設定 > プライバシーとセキュリティ > 自動化 で与えます"
        fi
      else
        # ここは意図的に「止まってよい」経路。拒否されたら保存の機会になる。
        if asuser /usr/bin/osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1; then
          log "logout requested"
        elif automation_probe >/dev/null; then
          # System Events には届いた。つまり許可はあり、断ったのはアプリ側。
          log "logout request failed: アプリが拒否した可能性があります"
        else
          log "logout request failed: automation denied（システム設定 > プライバシーとセキュリティ > 自動化 で許可してください）"
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
        alert "$(mark "${KILL_AT} — ここで終了します")" \
              "本番ならこの時点で終了していました（レベル: ${LEVEL}）。まだ動いているのはドライラン中だからです。" 60
        exit 0
      fi
      # 本番でここまで来たことを残す。導入しても「本当に効くのか」は
      # 一度落ちるまで分からないので、status がこの行を見て経路の生死を出す。
      # 別ファイルに持つとログと食い違うため、記録はログ1本に寄せる。
      log "enforce reached level=$LEVEL"
      case "$LEVEL" in
        notify)
          log "level=notify: 通知のみ"
          alert "${KILL_AT} — 終業時刻です" "設定はレベル notify なので電源は落としません。" 60
          ;;
        soft)
          # soft は OS 側の終了確認ダイアログが出るので、こちらからは出さない。
          log "level=soft: アプリに終了を依頼"
          asuser /usr/bin/osascript -e 'tell application "System Events" to shut down' >/dev/null 2>&1 \
            || log "soft shutdown が拒否された"
          ;;
        normal)
          log "level=normal: shutdown -h now"
          # 画面に理由を出してから落とす。スリープ復帰が猶予内に入ると
          # 予告も警告も見ないまま電源が落ちるため、無言だとクラッシュと
          # 区別が付かない。閉じても中断はされない。
          alert "${KILL_AT} — 終了します" \
                "enddayd が終業時刻として電源を落とします。中断はできません。" "$ENFORCE_ALERT_SEC"
          sleep 2
          /sbin/shutdown -h now
          ;;
        hard)
          log "level=hard: セッションを畳んでから shutdown"
          alert "${KILL_AT} — 終了します" \
                "enddayd が終業時刻として電源を落とします。保存していない変更は失われます。" "$ENFORCE_ALERT_SEC"
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
  require_valid_conf || return 1
  local entries="" d t h m slot last at
  last=$(to_min "${T_ARR[3]}")
  for d in "${W_ARR[@]}"; do
    for t in "${T_ARR[@]}"; do
      h=$((10#${t%%:*})); m=$((10#${t##*:}))
      entries+="    <dict><key>Weekday</key><integer>${d}</integer>"
      entries+="<key>Hour</key><integer>${h}</integer>"
      entries+="<key>Minute</key><integer>${m}</integer></dict>"$'\n'
    done
    # 「今日だけ延ばす」の受け皿。トリガは plist に固定で書くものなので、
    # 延ばした先に発火が無ければ何も起きない。選べる分数と1対1で置く。
    # 延長していない日は run が「窓の外」と判定して何もしない。
    for slot in $EXTEND_SLOTS; do
      at=$((last + slot))
      [ "$at" -gt $((24 * 60 - 1)) ] && continue   # 日をまたぐぶんは置かない
      entries+="    <dict><key>Weekday</key><integer>${d}</integer>"
      entries+="<key>Hour</key><integer>$((at / 60))</integer>"
      entries+="<key>Minute</key><integer>$((at % 60))</integer></dict>"$'\n'
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
  <string>${ERRLOG}</string>
</dict>
</plist>
EOF
}

write_conf() {
  cat >"$CONF" <<EOF
# enddayd 設定ファイル。手で編集したら sudo $BIN reload を実行してください。
# reload は内容を検証し、通らなければ何も差し替えません。
TIMES="$TIMES"
WEEKDAYS="$WEEKDAYS"
LEVEL="$LEVEL"
LOGOUT_ATTEMPT="$LOGOUT_ATTEMPT"
ALLOW_BYPASS="$ALLOW_BYPASS"
KILL_GRACE="$KILL_GRACE"
EOF
  chmod 644 "$CONF"; chown root:wheel "$CONF"
}

# plist は一時ファイルに書いて検査してから差し替える。直接リダイレクトすると
# 生成が途中で失敗したときに 0 バイトの plist が残り、bootout 済みのまま
# bootstrap も失敗して、デーモンが黙って消える。
load_daemon() {
  require_valid_conf || return 1

  local tmp="${PLIST}.new.$$"
  if ! gen_plist >"$tmp"; then
    rm -f "$tmp"; echo "plist の生成に失敗しました" >&2; return 1
  fi
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"; echo "生成した plist が不正です（差し替えていません）" >&2; return 1
    fi
  fi

  /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
  chown root:wheel "$tmp" 2>/dev/null || true
  chmod 644 "$tmp"
  if ! mv "$tmp" "$PLIST"; then
    rm -f "$tmp"; echo "$PLIST を更新できませんでした" >&2; return 1
  fi
  if ! /bin/launchctl bootstrap system "$PLIST"; then
    echo "/bin/launchctl bootstrap に失敗しました（${PLIST}）" >&2; return 1
  fi
  /bin/launchctl enable "system/${LABEL}" || true
  return 0
}

# ログのローテーション設定を置く。
#
# ログは追記のみで、放っておくと伸び続ける。1日4行程度なので実害が出るのは
# 何年も先だが、rehearsal を繰り返すと増える。newsyslog は macOS 標準なので
# 追加のデーモンは要らない。
#
# 失敗しても導入は止めない。ローテーションが無くても終業の機能は動くので、
# ここで止めるほうが害が大きい。
write_newsyslog() {
  local dir tmp
  dir=$(dirname "$NEWSYSLOG")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { echo "$dir を作成できませんでした（ログは伸び続けます）" >&2; return 1; }

  tmp="${NEWSYSLOG}.new.$$"
  # 書式は macOS 標準の drop-in（/etc/newsyslog.d/wifi.conf 等）に合わせる。
  # owner:group は省略できるので書かない。newsyslog は root で走り、ログも
  # root のものなので効果は変わらず、項目が少ないほど解釈を誤られにくい。
  #   size は KB。100KB を超えたら回し、5世代を bzip2（J）で残す。
  #   when が * なので大きさだけで判断する（時刻では回さない）。
  {
    echo "# enddayd が置いたもの。uninstall で消える。"
    echo "# logfilename          [owner:group]    mode count size when  flags"
    printf '%-38s %s\n' "$LOG"    "644  5     100  *     J"
    printf '%-38s %s\n' "$ERRLOG" "644  5     100  *     J"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; echo "$NEWSYSLOG を書けませんでした（ログは伸び続けます）" >&2; return 1; }

  if ! mv "$tmp" "$NEWSYSLOG"; then
    rm -f "$tmp"; echo "$NEWSYSLOG を更新できませんでした（ログは伸び続けます）" >&2; return 1
  fi
  chmod 644 "$NEWSYSLOG" 2>/dev/null || true
  return 0
}

# 本体を $BIN へ置く。親ディレクトリは install が作らないので先に作る。
install_self() {
  local self dir
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

  # curl … | sudo bash では $0 が "bash" になり、本体の場所が分からない。
  # そのまま進むと cwd の別ファイルを配置しかねないので、ここで止める。
  if [ ! -f "$self" ]; then
    {
      echo "本体の場所を特定できません（パイプ経由で実行していませんか）"
      echo "  いったんファイルに保存してから実行してください:"
      echo "  curl -fsSL https://raw.githubusercontent.com/BoxPistols/enddayd/main/enddayd.sh -o enddayd.sh"
      echo "  sudo bash enddayd.sh setup"
    } >&2
    return 1
  fi

  dir=$(dirname "$BIN")
  if [ ! -d "$dir" ]; then
    if ! install -d -m 755 -o root -g wheel "$dir"; then
      echo "$dir を作成できませんでした" >&2; return 1
    fi
  fi
  # 既に $BIN 自身を実行しているときは何もしない（install は同一ファイルを拒む）
  [ "$self" = "$BIN" ] && return 0
  if ! install -m 755 -o root -g wheel "$self" "$BIN"; then
    echo "$BIN に配置できませんでした" >&2; return 1
  fi
  return 0
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

  if [ -n "$CONF_ERRORS" ]; then
    echo "いまの $CONF は読めない状態です。この setup で上書きされます:"
    echo "$CONF_ERRORS"
    echo
  fi

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
  local defaults i
  # 壊れた conf から来た場合に備え、既定値は素の TIMES から取り直す
  IFS=',' read -r -a defaults <<<"$TIMES"
  if [ "${#defaults[@]}" -ne 4 ]; then
    IFS=',' read -r -a defaults <<<"18:00,18:30,18:45,18:50"
  fi
  local new=() prev=-1 cur
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
         [ "$(lower "$REPLY_VAL")" = "yes" ] && break
         LEVEL=normal; echo "  → normal に戻しました" >&2; break ;;
      *) echo "  → 1〜4 で入力してください" >&2 ;;
    esac
  done
  echo

  # --- 細かい挙動 ---
  ask "警告の段階でログアウトを試みますか (y/n)" "$([ "$LOGOUT_ATTEMPT" = 1 ] && echo y || echo n)"
  [ "$(lower "$REPLY_VAL")" = "y" ] && LOGOUT_ATTEMPT=1 || LOGOUT_ATTEMPT=0

  ask "当日スキップ（${BYPASS}）を許しますか (y/n)" "$([ "$ALLOW_BYPASS" = 1 ] && echo y || echo n)"
  [ "$(lower "$REPLY_VAL")" = "y" ] && ALLOW_BYPASS=1 || ALLOW_BYPASS=0

  while :; do
    ask "最終段階を受け付ける猶予（分）" "$KILL_GRACE"
    case "$REPLY_VAL" in
      ''|*[!0-9]*) echo "  → 0 以上の整数で入力してください" >&2 ;;
      *) KILL_GRACE="$REPLY_VAL"; break ;;
    esac
  done
  echo

  # --- 導入後のモード ---
  # 本番で動いているものを設定変更だけで黙ってドライランへ戻さない。
  # 「効かなくなったことに気づけない」のがこのツールで一番まずい壊れ方。
  local target_dry=1
  if [ -f "$BIN" ] && [ ! -f "$DRYFLAG" ]; then
    echo "【モード】いまは本番です（設定した時刻に実際に終了します）"
    ask "  設定を変えたあとも本番のまま続けますか (y/n)" "y"
    [ "$(lower "$REPLY_VAL")" = "y" ] && target_dry=0 || target_dry=1
    echo
  fi
  if [ "$target_dry" = "1" ]; then MODE_OVERRIDE="ドライラン"; else MODE_OVERRIDE="本番"; fi

  # --- 確認 ---
  # 対話の各項目は入力時に見ているが、保存する形に組み立てたものを
  # もう一度通す。対話側の取りこぼしがあってもここで止まる。
  CONF_SYNTAX_ERROR=0   # これから書き換えるので、古いファイルの構文は無関係
  if ! validate_conf; then
    echo "入力された設定が検証を通りませんでした:" >&2
    echo "$CONF_ERRORS" >&2
    exit 1
  fi
  echo "----------------------------------------------"
  cmd_config_body
  echo "----------------------------------------------"
  ask "この内容で導入しますか (yes/no)" "yes"
  if [ "$(lower "$REPLY_VAL")" != "yes" ]; then
    echo "中止しました。"; exit 0
  fi

  install_self || exit 1
  write_conf
  write_newsyslog || true
  if [ "$target_dry" = "1" ]; then touch "$DRYFLAG"; else rm -f "$DRYFLAG"; fi
  load_daemon || exit 1
  if ! daemon_loaded; then
    echo "デーモンの登録を確認できませんでした（sudo $BIN status で確認してください）" >&2
    exit 1
  fi

  echo
  if [ "$target_dry" = "1" ]; then
    echo "導入しました（ドライラン中：まだ終了しません）"
  else
    echo "導入しました（本番：次回 ${T_ARR[3]} に レベル ${LEVEL} で終了します）"
  fi
  ask "いま全段階を通しで確認しますか (y/n)" "y"
  if [ "$(lower "$REPLY_VAL")" = "y" ]; then
    ENDDAYD_DRY_RUN=1 cmd_rehearsal 5
  fi
  echo
  if [ "$target_dry" = "1" ]; then
    echo "本番に切り替える: sudo $BIN dryrun off"
  fi
}

# --------------------------------------------------------- サブコマンド ---

cmd_install() {
  need_root
  require_valid_conf || exit 1
  # 新規かどうかを配置の前に見る。本番で動いているものを入れ直しただけで
  # 黙ってドライランへ戻すと、効かなくなったことに気づけない。setup は
  # 対話で尋ねているが、install には尋ねる場が無いので現状を保つ。
  local fresh=0
  [ -f "$BIN" ] || fresh=1
  install_self || exit 1
  [ -f "$CONF" ] || write_conf
  write_newsyslog || true
  [ "$fresh" = "1" ] && touch "$DRYFLAG"
  load_daemon || exit 1
  if ! daemon_loaded; then
    echo "デーモンの登録を確認できませんでした（sudo $BIN status で確認してください）" >&2
    exit 1
  fi
  if [ "$fresh" = "1" ]; then
    echo "導入しました（ドライラン中：まだ終了しません）"
  elif [ -f "$DRYFLAG" ]; then
    echo "入れ直しました（ドライランのまま：まだ終了しません）"
  else
    echo "入れ直しました（本番のまま：設定した時刻に実際に終了します）"
  fi
  echo "  設定を変える: sudo $BIN setup"
  echo "  通しで確認  : sudo $BIN rehearsal"
  echo "  本番に切替  : sudo $BIN dryrun off"
}

cmd_reload() {
  need_root
  require_valid_conf || exit 1
  load_daemon || exit 1
  echo "設定を読み直しました。"
  cmd_config_body
}

cmd_uninstall() {
  need_root
  # plist が壊れていたり既に消えていたりしても外せるよう、ラベル指定も試す
  /bin/launchctl bootout system "$PLIST" 2>/dev/null \
    || /bin/launchctl bootout "system/${LABEL}" 2>/dev/null \
    || true
  rm -f "$PLIST" "$BIN" "$DRYFLAG" "$BYPASS" "$NEWSYSLOG" "$TODAY_FILE"

  if daemon_loaded; then
    echo "デーモンをまだ外せていません。次を実行してください:" >&2
    echo "  sudo launchctl bootout system/${LABEL}" >&2
    exit 1
  fi
  echo "削除しました（設定 $CONF とログ $LOG は残しています）。"
  echo "設定も消すなら: sudo rm -f $CONF"
}

# 今日だけの調整。当日スキップと同じく日付印を押すので、翌日は勝手に失効する。
cmd_today() {
  need_root
  require_valid_conf || exit 1
  local action="${1:-show}" value="${2:-}"

  case "$action" in
    show)
      read_today
      [ -n "$TODAY_ERROR" ] && { echo "今日の調整は無視されます: $TODAY_ERROR" >&2; exit 1; }
      local summary
      summary=$(today_summary)
      if [ -z "$summary" ]; then
        echo "今日の調整: なし（通常のスケジュールで動きます）"
      else
        echo "今日の調整: $summary"
        echo "強制終了  : $(to_hhmm $(( $(to_min "${T_ARR[3]}") + TODAY_EXTEND )))"
        echo "明日には自動的に元へ戻ります。"
      fi
      ;;

    extend)
      case " $EXTEND_SLOTS " in
        *" $value "*) ;;
        *) echo "延長できるのは $EXTEND_SLOTS 分のいずれかです（受け皿のトリガと対になっているため）" >&2; exit 1 ;;
      esac
      write_today "$value" ""
      ;;

    level)
      case "$value" in
        notify|soft|normal|hard) ;;
        *) echo "レベルは notify / soft / normal / hard のいずれかです" >&2; exit 1 ;;
      esac
      read_today
      write_today "$TODAY_EXTEND" "$value"
      ;;

    clear)
      rm -f "$TODAY_FILE"
      echo "今日の調整を取り消しました。"
      ;;

    *)
      echo "usage: sudo $0 today [show|extend <分>|level <名前>|clear]" >&2
      echo "  延長できる分数: $EXTEND_SLOTS" >&2
      exit 1 ;;
  esac
}

# 上書きファイルを書く。書いたあとに読み直して、受け付けられたことを確かめる。
# 「書けた」と「効く」は別なので、書けただけで成功と言わない。
write_today() {
  local extend="${1:-0}" level="${2:-}" tmp
  tmp="${TODAY_FILE}.new.$$"
  # 条件付きの出力を `[ … ] && echo` で書かないこと。グループの終了コードは
  # 最後の要素のものなので、条件が偽なだけで「書き込みに失敗した」と
  # 誤判定する（実際に踏んだ）。成否は書けたものを見て判断する。
  {
    echo "# enddayd が置いた当日限りの上書き。日付が変われば自動的に無効になる。"
    echo "DATE=$(date +%F)"
    if [ "$extend" -gt 0 ] 2>/dev/null; then echo "EXTEND=${extend}"; fi
    if [ -n "$level" ]; then echo "LEVEL=${level}"; fi
  } >"$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"; echo "$TODAY_FILE を書けませんでした" >&2; exit 1
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv "$tmp" "$TODAY_FILE" || { rm -f "$tmp"; echo "$TODAY_FILE を更新できませんでした" >&2; exit 1; }

  read_today
  if [ -n "$TODAY_ERROR" ]; then
    rm -f "$TODAY_FILE"
    echo "受け付けられませんでした: $TODAY_ERROR" >&2
    exit 1
  fi
  echo "今日の調整: $(today_summary)"
  echo "強制終了  : $(to_hhmm $(( $(to_min "${T_ARR[3]}") + TODAY_EXTEND )))"
  echo "明日には自動的に元へ戻ります。"
}

cmd_dryrun() {
  need_root
  case "${1:-}" in
    on)  touch "$DRYFLAG"; echo "ドライラン: ON（終了処理は実行しません）" ;;
    off) require_valid_conf || exit 1
         rm -f "$DRYFLAG"
         echo "ドライラン: OFF（次回 ${T_ARR[3]} に レベル ${LEVEL} で終了します）"
         daemon_loaded || echo "注意: デーモンが登録されていません。sudo $BIN install を実行してください" >&2 ;;
    *)   echo "usage: sudo $0 dryrun on|off" >&2; exit 1 ;;
  esac
}

cmd_config_body() {
  if [ -n "$CONF_ERRORS" ]; then
    echo "設定エラー  : 直すまで終業は実行されません"
    echo "$CONF_ERRORS"
    echo "生の値      : TIMES=\"$TIMES\" WEEKDAYS=\"$WEEKDAYS\" LEVEL=\"$LEVEL\" KILL_GRACE=\"$KILL_GRACE\""
    return 1
  fi
  local d names=""
  for d in "${W_ARR[@]}"; do names="${names}$(dow_name "$d")"; done
  echo "曜日        : $names"
  echo "予告        : ${T_ARR[0]}"
  echo "警告        : ${T_ARR[1]}  （ログアウト試行: $([ "$LOGOUT_ATTEMPT" = 1 ] && echo あり || echo なし)）"
  echo "最終通告    : ${T_ARR[2]}"
  echo "強制終了    : ${T_ARR[3]}  （猶予 ${KILL_GRACE}分）"
  echo "レベル      : $(level_label "$LEVEL")"
  echo "当日スキップ: $([ "$ALLOW_BYPASS" = 1 ] && echo 許可 || echo 不可)"
  if [ -n "${MODE_OVERRIDE:-}" ]; then
    echo "モード      : $MODE_OVERRIDE"
  else
    echo "モード      : $([ -f "$DRYFLAG" ] && echo ドライラン || echo 本番)"
  fi
  if [ -n "$CONF_WARNINGS" ]; then
    echo "注意        : 設定は有効ですが、書いたとおりには効きません"
    echo "$CONF_WARNINGS"
  fi
  return 0
}

cmd_config() { cmd_config_body; echo; echo "設定ファイル: $CONF"; }

cmd_status() {
  cmd_config_body || true
  if [ -f "$BIN" ]; then echo "スクリプト  : $BIN"; else echo "スクリプト  : 未導入"; fi
  if daemon_loaded; then
    echo "デーモン    : 登録済み"
  else
    echo "デーモン    : 未登録"
  fi
  read_today
  local today_line
  today_line=$(today_summary)
  if [ -n "$TODAY_ERROR" ]; then
    echo "今日の調整  : 無視されます（${TODAY_ERROR}）"
  elif [ -n "$today_line" ]; then
    echo "今日の調整  : ${today_line}（明日には戻ります）"
  fi

  # ドライランの行には log() が [DRY] を付けるので、本番の到達だけを拾える。
  local reached
  reached=$(grep -Fv '[DRY]' "$LOG" 2>/dev/null | grep -F 'enforce reached' | tail -n 1)
  if [ -n "$reached" ]; then
    echo "本番到達    : ${reached/enforce reached /}"
  else
    echo "本番到達    : まだありません（強制終了の経路は未確認）"
  fi
  [ -f "$BYPASS" ] && echo "スキップ指定: $(cat "$BYPASS")"
  echo "--- 直近のログ ---"
  tail -n 10 "$LOG" 2>/dev/null || echo "(まだありません)"
  if [ -s "$ERRLOG" ]; then
    echo "--- エラー出力（$ERRLOG の末尾3行）---"
    tail -n 3 "$ERRLOG"
  fi
}

cmd_rehearsal() {
  need_root
  require_valid_conf || exit 1
  local gap="${1:-20}" s m
  case "$gap" in
    ''|*[!0-9]*) echo "秒数は 0 以上の整数で指定してください" >&2; exit 1 ;;
  esac
  echo "全段階を ${gap} 秒間隔で通します。実際には終了しません。中断は Ctrl-C。"
  for s in notice warn final enforce; do
    m=$(stage_min "$s") || exit 1
    echo "--- $s ---"
    ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$m" bash "$0" run || true
    [ "$s" = "enforce" ] || sleep "$gap"
  done
  echo "リハーサル完了。"
}

cmd_stage() {
  need_root
  require_valid_conf || exit 1
  local m
  m=$(stage_min "${1:-notice}") || exit 1
  ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$m" bash "$0" run
}

usage() { sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'; }

case "${1:-}" in
  run)        cmd_run ;;
  setup)      cmd_setup ;;
  install)    cmd_install ;;
  reload)     cmd_reload ;;
  uninstall)  cmd_uninstall ;;
  config)     cmd_config ;;
  dryrun)     cmd_dryrun "${2:-}" ;;
  today)      cmd_today "${2:-show}" "${3:-}" ;;
  status)     cmd_status ;;
  rehearsal)  cmd_rehearsal "${2:-}" ;;
  stage)      cmd_stage "${2:-notice}" ;;
  plist)      require_valid_conf || exit 1; gen_plist ;;
  log)        tail -f "$LOG" ;;
  *)
    usage
    exit 1
    ;;
esac
