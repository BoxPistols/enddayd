# テスト用ヘルパ
#
# enddayd.sh は macOS 固有のバイナリを絶対パスで呼ぶ。テストでは
# そのパスをスタブに差し替えたコピーを作り、CI（Linux）でも
# ステージ判定と設定まわりを検証できるようにする。
#
# テスト名を ASCII にしているのは bats 1.11 以降が非 ASCII のテスト名を
# 「unknown test name」として読み飛ばすため（1.10 以前は実行できる）。
# 日本語は各テストの上の説明コメントに置く。

setup_sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/etc"

  cat >"$SANDBOX/bin/stat" <<'EOF'
#!/bin/bash
echo "testuser"
EOF
  cat >"$SANDBOX/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then echo 501; else echo 0; fi
EOF
  # 登録状態を持つ。print が常に失敗する固定スタブだと、bootstrap まで
  # 進んだかどうかを見分けられず「登録を確認できませんでした」で終わる。
  cat >"$SANDBOX/bin/launchctl" <<EOF
#!/bin/bash
# asuser <uid> <cmd...> のみ通す
if [ "\${1:-}" = "asuser" ]; then shift 2; exec "\$@"; fi
case "\${1:-}" in
  bootstrap) : >"$SANDBOX/daemon.loaded" ;;
  bootout)   rm -f "$SANDBOX/daemon.loaded" ;;
  print)     [ -f "$SANDBOX/daemon.loaded" ] || exit 1 ;;
esac
exit 0
EOF
  cat >"$SANDBOX/bin/sudo" <<'EOF'
#!/bin/bash
shift 2   # -u <user>
exec "$@"
EOF
  cat >"$SANDBOX/bin/osascript" <<'EOF'
#!/bin/bash
case "$*" in
  *"application process"*) echo "iTerm2, Chrome" ;;
esac
exit 0
EOF
  cat >"$SANDBOX/bin/afplay" <<'EOF'
#!/bin/bash
exit 0
EOF
  # 本物を絶対に呼ばないための番人。本番モードの経路をテストするには
  # ここが差し替わっていることが前提になる（下で確認する）。
  cat >"$SANDBOX/bin/shutdown" <<EOF
#!/bin/bash
echo "shutdown \$*" >>"$SANDBOX/shutdown.calls"
exit 0
EOF
  chmod +x "$SANDBOX"/bin/*
  : >"$SANDBOX/sound"

  SCRIPT="$SANDBOX/enddayd.sh"
  sed \
    -e "s#/usr/bin/stat#$SANDBOX/bin/stat#g" \
    -e "s#/usr/bin/id#$SANDBOX/bin/id#g" \
    -e "s#/bin/launchctl#$SANDBOX/bin/launchctl#g" \
    -e "s#/usr/bin/sudo#$SANDBOX/bin/sudo#g" \
    -e "s#/usr/bin/osascript#$SANDBOX/bin/osascript#g" \
    -e "s#/usr/bin/afplay#$SANDBOX/bin/afplay#g" \
    -e "s#/sbin/shutdown#$SANDBOX/bin/shutdown#g" \
    -e "s#^BIN=.*#BIN=$SANDBOX/installed/enddayd.sh#" \
    -e "s#^PLIST=.*#PLIST=$SANDBOX/installed/local.enddayd.plist#" \
    -e "s#^LOG=.*#LOG=$SANDBOX/enddayd.log#" \
    -e "s#^ERRLOG=.*#ERRLOG=$SANDBOX/enddayd.err.log#" \
    -e "s#^BYPASS=.*#BYPASS=$SANDBOX/etc/skip#" \
    -e "s#^DRYFLAG=.*#DRYFLAG=$SANDBOX/etc/dryrun#" \
    -e "s#^CONF=.*#CONF=$SANDBOX/etc/conf#" \
    -e "s#^NEWSYSLOG=.*#NEWSYSLOG=$SANDBOX/etc/newsyslog.d/enddayd.conf#" \
    -e "s#^GRACE_SOUND=.*#GRACE_SOUND=$SANDBOX/sound#" \
    -e "s#^FINAL_SOUND=.*#FINAL_SOUND=$SANDBOX/sound#" \
    "$BATS_TEST_DIRNAME/../enddayd.sh" >"$SCRIPT"
  chmod +x "$SCRIPT"

  # 置換が効かないまま本番モードのテストを走らせると、実行しているマシンが
  # 本当に落ちる。スタブ先（$SANDBOX/bin/shutdown）は /sbin/shutdown を
  # 含まないので、残っていれば置換の失敗と断定できる。
  if grep -q '/sbin/shutdown' "$SCRIPT"; then
    echo "サンドボックスの置換に失敗しました: /sbin/shutdown が残っています" >&2
    return 1
  fi
}

# 本番モードで osascript が System Events を操作できない状態を作る。
# 「自動化」が未許可のときの macOS の挙動に合わせ、System Events 宛ての
# Apple Event だけが失敗し、osascript 自身の UI（display alert）は通る。
deny_automation() {
  cat >"$SANDBOX/bin/osascript" <<'EOF'
#!/bin/bash
case "$*" in
  *"System Events"*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/bin/osascript"
}

# write_conf_file KEY=VALUE ...
write_conf_file() {
  : >"$SANDBOX/etc/conf"
  local kv
  for kv in "$@"; do echo "$kv" >>"$SANDBOX/etc/conf"; done
}

# write_conf_raw : 標準入力をそのまま conf にする（構文エラーを作るため）
write_conf_raw() { cat >"$SANDBOX/etc/conf"; }

# run_at <分> : その時刻に発火したものとして run を実行する
# stderr は捨てずにファイルへ分ける。捨てると unbound variable のような
# 「静かな失敗」がテストから見えなくなる。
run_at() {
  ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$1" bash "$SCRIPT" run 2>"$SANDBOX/stderr"
}

# run_at_live <分> : 本番モード（ドライランなし）でその時刻に発火させる。
# ドライランでは通らない経路（enforce の到達記録、ログアウトの実試行）を
# 見るために要る。/sbin/shutdown は setup_sandbox がスタブに差し替え、
# 差し替えの失敗はそこで止まる。
run_at_live() {
  ENDDAYD_FORCE_MIN="$1" bash "$SCRIPT" run 2>"$SANDBOX/stderr"
}

# 本番モードで shutdown が呼ばれたか
shutdown_calls() { cat "$SANDBOX/shutdown.calls" 2>/dev/null; }

# as_root <コマンド…> : need_root を通すために uid 0 を返す id だけを差し込む
# （PATH の先頭に置くのは id のみ。他のコマンドは実物のまま）
as_root() {
  mkdir -p "$SANDBOX/rootbin"
  cat >"$SANDBOX/rootbin/id" <<'EOF'
#!/bin/bash
echo 0
EOF
  chmod +x "$SANDBOX/rootbin/id"
  PATH="$SANDBOX/rootbin:$PATH" "$@"
}

# --- 表明 ---------------------------------------------------------------
#
# bash 3.2（macOS の /bin/bash）は [[ ]] の失敗で errexit を発動しない。
# テスト本体の途中に書いた [[ ]] は何を返しても素通りし、最後の1行だけが
# 合否を決めてしまう。つまり途中の表明は検証していないのと同じになる。
# 実測: /bin/bash 3.2.57 で `bash -ec '[[ a == b ]]; echo X'` が X を出して
# 0 で終わる（`[ a = b ]` は 1 で止まる）。macOS は 3.2 のままなのでここは
# 踏む。bash 4 以降で直っているとされるが、このリポジトリでは未確認。
#
# 関数呼び出しなら単純コマンドとして扱われ、どのバージョンでも止まる。
# 表明はこの2つで書くこと。生きていることは
# 「harness: a failed expectation in the middle stops the test」が見ている。

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) echo "期待した文字列がありません: $2" >&2; return 1 ;;
  esac
}

not_contains() {
  case "$1" in
    *"$2"*) echo "あってはならない文字列があります: $2" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

# as_root_installable <コマンド…> : need_root に加えて install(1) も通す。
# 本物の install は root 所有での配置を要求するのでサンドボックスでは通らない。
# ここで差し替えるのは「配置できた前提の分岐」（導入済みかどうかでモードを
# どう扱うか）を見るためで、本物の install が通ることの担保にはならない
# （docs/known-issues.md「導入経路にテストが無い」）。
as_root_installable() {
  mkdir -p "$SANDBOX/rootbin"
  cat >"$SANDBOX/rootbin/id" <<'EOF'
#!/bin/bash
echo 0
EOF
  cat >"$SANDBOX/rootbin/install" <<'EOF'
#!/bin/bash
# 所有者・パーミッションの指定は捨て、配置だけを再現する
mode=copy
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) mode=dir; shift ;;
    -m|-o|-g) shift 2 ;;
    -*) shift ;;
    *) files+=("$1"); shift ;;
  esac
done
if [ "$mode" = dir ]; then mkdir -p "${files[@]}"; else cp "${files[0]}" "${files[1]}"; fi
EOF
  chmod +x "$SANDBOX/rootbin/id" "$SANDBOX/rootbin/install"
  PATH="$SANDBOX/rootbin:$PATH" "$@"
}

# 直前の実行が stderr に出したもの
stderr_text() { cat "$SANDBOX/stderr" 2>/dev/null; }

# ログファイルの中身（status が見せるのはこちら）
log_text() { cat "$SANDBOX/enddayd.log" 2>/dev/null; }
