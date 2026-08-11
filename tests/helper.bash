# テスト用ヘルパ
#
# enddayd.sh は macOS 固有のバイナリを絶対パスで呼ぶ。テストでは
# そのパスをスタブに差し替えたコピーを作り、CI（Linux）でも
# ステージ判定と設定まわりを検証できるようにする。

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
  cat >"$SANDBOX/bin/launchctl" <<'EOF'
#!/bin/bash
# asuser <uid> <cmd...> のみ通す
if [ "${1:-}" = "asuser" ]; then shift 2; exec "$@"; fi
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
    -e "s#^LOG=.*#LOG=$SANDBOX/enddayd.log#" \
    -e "s#^BYPASS=.*#BYPASS=$SANDBOX/etc/skip#" \
    -e "s#^DRYFLAG=.*#DRYFLAG=$SANDBOX/etc/dryrun#" \
    -e "s#^CONF=.*#CONF=$SANDBOX/etc/conf#" \
    -e "s#^GRACE_SOUND=.*#GRACE_SOUND=$SANDBOX/sound#" \
    -e "s#^FINAL_SOUND=.*#FINAL_SOUND=$SANDBOX/sound#" \
    "$BATS_TEST_DIRNAME/../enddayd.sh" >"$SCRIPT"
  chmod +x "$SCRIPT"
}

# write_conf_file KEY=VALUE ...
write_conf_file() {
  : >"$SANDBOX/etc/conf"
  local kv
  for kv in "$@"; do echo "$kv" >>"$SANDBOX/etc/conf"; done
}

# run_at <分> : その時刻に発火したものとして run を実行する
run_at() {
  ENDDAYD_DRY_RUN=1 ENDDAYD_FORCE_MIN="$1" bash "$SCRIPT" run 2>/dev/null
}
