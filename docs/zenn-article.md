---
title: "AI駆動開発時代の「終業」を設計する — Macを平日18:50に強制シャットダウンさせる"
emoji: "🌇"
type: "tech"
topics: ["macos", "launchd", "shell", "claudecode", "生産性"]
published: false
---

## 疲れなくなったぶん、止まれなくなっていないか

エージェントに実装を任せるようになってから、終業のタイミングが分かりにくくなった、という話をよく聞くようになりました。心当たりのある方は多いのではないでしょうか。

興味深いのは、多くの場合「しんどいから長引いている」わけではないことです。手を動かす総量はむしろ減っている。それなのに終わる時刻だけが後ろにずれていく。

これは意志の弱さの問題ではなく、開発スタイルの変化がもたらす構造的なものだと考えています。理由は3つあると思います。

**疲労がブレーキとして機能しなくなりました。** 自分で全部書いていた頃は、集中力が切れた時点で自然に手が止まっていました。今は自分の集中力ではなく、エージェントのターンが終わるタイミングで区切りが決まります。指示を出して、待って、差分を見て、直す。この待ち時間が細切れに入るせいで、消耗の実感が薄いまま時間だけが進みます。

**「あと1回だけ回す」が安すぎます。** 以前なら「この改善は明日やろう」と判断していた作業が、指示1行で終わる見込みになりました。1回のコストが下がったので、やることリストが減らない。むしろ「ついでにこれも」が無限に生えます。

**結果が確率的です。** 一発で通ることもあれば、3回やり直すこともある。この「次は当たるかもしれない」という感触は、切り上げる判断とかなり相性が悪いです。区切りが自分で決まらない。

つまりAI駆動開発は、生産性を上げる一方で、**自分で終業を判断する材料を静かに奪っていく**側面があります。判断材料がないところに意志を求めても仕方がないので、判断そのものを外部化するのが筋だと考えました。

そこで、Macを平日18:50に、いかなる状態でも強制的に落とす仕組みを作りました。以下はその実装と、設計上考えたことです。

## 標準機能では止められない

macOS 12 Monterey までは、システム環境設定の「バッテリー / 省エネルギー」に「スケジュール」があり、起動・スリープ・再起動・システム終了を時刻指定できました。

これは macOS 13 Ventura でシステム設定アプリが刷新された際にGUIごと廃止されています。以降はターミナルの `pmset` で設定します。

```bash
# 毎日23:00にシャットダウン
sudo pmset repeat shutdown MTWRFSU 23:00:00

# 確認 / 解除
pmset -g sched
sudo pmset repeat cancel
```

曜日は `M T W R(木) F S(土) U(日)`。手軽ですが、今回の目的には3つ足りません。

1. **スリープ中は発火しません。** Appleのドキュメントにも、指定時刻にシステム終了するにはMacがスリープしておらずユーザーがログインしている必要がある、と書かれています。ノートだと蓋を閉じた時点で無効になります。
2. **確認ダイアログが出ます。** 実行前に猶予が与えられるので、意志で回避できてしまいます。意志が信用できないから作っているのに、意志に判断を委ねる設計では意味がありません。
3. **ターミナルが止めます。** これが決定打でした。`pmset` のシャットダウンは各アプリに終了を依頼する経路を通ります。iTerm でプロセスが走っていれば「本当に終了しますか」で止まります。ターミナル中心で作業している限り、まず落ちません。

3つ目が本質的です。回避可能な仕組みは、回避したい日に必ず回避されます。

## 設計

というわけで自作しました。要件はこうです。

| 時刻 | 動作 |
| --- | --- |
| 18:00 | 終了準備を促すアラート |
| 18:30 | 警告。ログアウトを試みる（ここは止まってよい） |
| 18:45 | 最終通告。5分後に落とすと予告 |
| 18:50 | `shutdown -h now`。何があっても落とす |

月〜金のみ。時刻はスクリプト先頭の `TIMES` / `WEEKDAYS` で変えられるので、ここでは一例として18時台を置いています。設計上のポイントは4つです。

### 1. root の LaunchDaemon から直接落とす

アプリの拒否権を通らない経路が必要です。root権限の LaunchDaemon から `/sbin/shutdown -h now` を直接呼べば、「終了してよいですか」のダイアログは挟まりません。ユーザー権限の LaunchAgent や AppleScript 経由では、ここが必ず止まります。

18:30 のログアウトだけは、あえて止まる側の経路（`System Events` への `log out`）にしています。未保存の書類があるアプリが拒否したら、それは保存の機会として機能するからです。段階の役割を分けています。

### 2. 段階的にエスカレーションさせる

いきなり落とすと作業が飛びます。飛ぶのが嫌でツールごと外す、という結末になりがちです。

18:00 は予告、18:30 は本命の締切、18:45 は「本当に落ちる」の再確認。この3段があると、18:50 に驚くことがなくなります。実際に運用してみると、効いているのは18:30の警告で、18:50 はそこに実効性を持たせるための担保として働いています。**予告が守られる保証がないと、予告は無視されます。**

### 3. ステージは「時計」で決める

launchd の `StartCalendarInterval` は、指定時刻にマシンがスリープしていた場合、復帰後に遅延実行されます。素直に「18:50のジョブ＝シャットダウン」と書くと、翌朝に蓋を開けた瞬間に電源が落ちます。

なので各時刻に個別のトリガを置きつつ、スクリプト側は **起動時の現在時刻** を見て自分がどのステージかを判定します。時間帯を外れていれば何もせず終了します。

```bash
MIN=$((10#$(date +%H) * 60 + 10#$(date +%M)))
# 18:00=1080  18:30=1110  18:45=1125  18:50=1130

if   [ "$MIN" -ge 1080 ] && [ "$MIN" -lt 1110 ]; then STAGE=notice
elif [ "$MIN" -ge 1110 ] && [ "$MIN" -lt 1125 ]; then STAGE=warn
elif [ "$MIN" -ge 1125 ] && [ "$MIN" -lt 1130 ]; then STAGE=final
elif [ "$MIN" -ge 1130 ] && [ "$MIN" -le 1140 ]; then STAGE=enforce
else
  log "skip: out of window (min=$MIN)"
  exit 0
fi
```

最後のステージだけ 18:50〜19:00 の幅を持たせてあります。18:47 に蓋を閉じて18:55に開き直す、という回避を潰すためです。

### 4. 逃げ道は残す。ただし摩擦を置く

リリース前日に強制終了されると困ります。ただし逃げ道が簡単だと、毎日そこを通ります。

`/etc/enddayd.skip` に当日の日付を書いた場合だけスキップする、という形にしました。

```bash
sudo sh -c 'date +%F > /etc/enddayd.skip'
```

`sudo` を打ち、日付を書き込むという手間が、「今日は本当に必要か」を1回考えさせます。日付が一致した日しか効かないので、書きっぱなしで無効化され続けることもありません。

## 実装

macOS 専用です。`launchctl` / `osascript` / `stat -f` に依存しているので他OSでは動きません。考え方だけなら、Linux は systemd timer + `systemctl poweroff`、Windows はタスクスケジューラ + `shutdown.exe /s /f` で同じことができます。

1ファイルにまとめてあります。サブコマンドで導入・検証・削除まで済み、plist もスクリプト自身が生成します。

```bash
sudo ./enddayd.sh setup            # 対話的に時刻・曜日・強制レベルを設定して導入
sudo ./enddayd.sh install          # 既定値のまま導入
sudo ./enddayd.sh config           # 現在の設定を表示
sudo ./enddayd.sh dryrun on|off    # ドライランの切り替え
sudo ./enddayd.sh rehearsal 5      # 全段階を5秒間隔で通しで確認
sudo ./enddayd.sh uninstall        # 削除
```

設定は `/etc/enddayd.conf` に書き出され、最終段階の強制レベルを4段階から選べます。`notify`（通知のみ）、`soft`（アプリに依頼、拒否されれば止まる）、`normal`（rootから `shutdown`）、`hard`（セッションを畳んでから `shutdown`）。以下の本文は `normal` を前提にしています。

### 判定と各ステージ（`run` サブコマンドの中身）

以下は説明のために簡略化した版です。実物は時刻を設定ファイルから読み、強制レベルで分岐し、設定の検証を挟みます。動くものは[リポジトリ](https://github.com/BoxPistols/enddayd)の `enddayd.sh` を見てください。

```bash
#!/bin/bash
set -uo pipefail

LOG=/var/log/enddayd.log
BYPASS=/etc/enddayd.skip
DRYFLAG=/etc/enddayd.dryrun
GRACE_SOUND=/System/Library/Sounds/Sosumi.aiff
FINAL_SOUND=/System/Library/Sounds/Basso.aiff

DRY=0
if [ -f "$DRYFLAG" ] || [ "${ENDDAYD_DRY_RUN:-0}" = "1" ]; then
  DRY=1
fi

log() {
  local tag=""
  [ "$DRY" = "1" ] && tag="[DRY] "
  echo "$(date '+%F %T') ${tag}$*" >>"$LOG" 2>/dev/null
  [ "$DRY" = "1" ] && echo "$(date '+%F %T') ${tag}$*"
  return 0
}

mark() {
  if [ "$DRY" = "1" ]; then echo "【ドライラン】$1"; else echo "$1"; fi
}

# --- 実行してよい状況かの判定 ---
FORCE_MIN="${ENDDAYD_FORCE_MIN:-}"

DOW=$(date +%u)
if [ -z "$FORCE_MIN" ] && [ "$DOW" -gt 5 ]; then
  log "skip: weekend"; exit 0
fi

if [ -f "$BYPASS" ] && [ "$(cat "$BYPASS" 2>/dev/null)" = "$(date +%F)" ]; then
  log "skip: bypass file for today"; exit 0
fi

CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
  log "skip: no gui user"; exit 0
fi
CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER")

# --- GUIセッション側で実行するヘルパ ---
asuser() {
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"
}

play() {
  [ -f "$1" ] && asuser /usr/bin/afplay "$1" >/dev/null 2>&1 &
}

alert() {
  local title="$1" msg="$2" secs="$3"
  asuser /usr/bin/osascript \
    -e "display alert \"${title}\" message \"${msg}\" as critical giving up after ${secs}" \
    >/dev/null 2>&1
}

# --- ステージ判定（前掲）---
if [ -n "$FORCE_MIN" ]; then
  MIN="$FORCE_MIN"
else
  MIN=$((10#$(date +%H) * 60 + 10#$(date +%M)))
fi

if   [ "$MIN" -ge 1080 ] && [ "$MIN" -lt 1110 ]; then STAGE=notice
elif [ "$MIN" -ge 1110 ] && [ "$MIN" -lt 1125 ]; then STAGE=warn
elif [ "$MIN" -ge 1125 ] && [ "$MIN" -lt 1130 ]; then STAGE=final
elif [ "$MIN" -ge 1130 ] && [ "$MIN" -le 1140 ]; then STAGE=enforce
else
  log "skip: out of window (min=$MIN)"; exit 0
fi

log "stage=$STAGE user=$CONSOLE_USER"

case "$STAGE" in
  notice)
    play "$GRACE_SOUND"
    alert "$(mark "18:00 — 終業時刻です")" \
          "作業を切り上げる準備を始めてください。18:50 に電源を落とします。" 30
    ;;

  warn)
    play "$GRACE_SOUND"
    alert "$(mark "18:30 — ここで終わりです")" \
          "コミット・保存を済ませてください。これからログアウトを試みます。18:50 に強制的に電源が切れます。" 45
    if [ "$DRY" = "1" ]; then
      log "would request logout"
      # ログアウト試行には「自動化」の許可が要る。許可が無いと毎回失敗するが
      # 設計上そこでは止まらないので、ドライランのうちに成否を出しておく
      if apps=$(automation_probe); then
        log "automation ok"
        log "running apps: $apps"
      else
        log "automation denied（システム設定 > プライバシーとセキュリティ > 自動化）"
      fi
    else
      if asuser /usr/bin/osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1; then
        log "logout requested"
      elif automation_probe >/dev/null; then
        log "logout request failed: アプリが拒否した可能性があります"
      else
        log "logout request failed: automation denied"
      fi
    fi
    ;;

  final)
    play "$FINAL_SOUND"
    alert "$(mark "18:45 — 最終通告")" \
          "5分後、いかなる状態でも電源を落とします。未保存の変更は失われます。" 60
    ;;

  enforce)
    play "$FINAL_SOUND"
    if [ "$DRY" = "1" ]; then
      log "would run: /sbin/shutdown -h now"
      alert "$(mark "18:50 — ここで電源が切れます")" \
            "本番ならこの時点で強制的にシャットダウンされていました。" 60
    else
      # 本番でここまで来たことを残す。導入しても「本当に効くのか」は
      # 一度落ちるまで分からないので、status がこの行を見せる
      log "enforce reached"
      # 落とす前に理由を出す。スリープ復帰が猶予内に入ると予告も警告も
      # 見ないまま電源が落ちるので、無言だとクラッシュと区別が付かない。
      # 閉じても中断はされない
      alert "18:50 — 終了します" \
            "enddayd が終業時刻として電源を落とします。中断はできません。" 10
      sleep 2
      /sbin/shutdown -h now
    fi
    ;;
esac

exit 0
```

通知に `display notification` ではなく `display alert` を使っているのは意図的です。前者は通知許可の状態次第で無音のまま消えます。無視できる通知には、無視できるという以上の意味がありません。

### LaunchDaemon

plist は `install` サブコマンドが `/Library/LaunchDaemons/local.enddayd.plist`（644, root:wheel）に書き出します。`sudo ./enddayd.sh plist` で中身だけ確認できます。曜日1〜5 × 4時刻ぶんの `StartCalendarInterval` を並べたもので、以下は月曜の抜粋です。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.enddayd</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/enddayd.sh</string>
    <string>run</string>
  </array>

  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>45</integer></dict>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>50</integer></dict>
    <!-- Weekday 2〜5 も同様に -->
  </array>

  <key>StandardErrorPath</key>
  <string>/var/log/enddayd.err.log</string>
</dict>
</plist>
```

読み込みと解除は `install` / `uninstall` の中でやっていますが、手で叩くならこうです。

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/local.enddayd.plist
sudo launchctl enable system/local.enddayd

sudo launchctl bootout system /Library/LaunchDaemons/local.enddayd.plist
```

## ドライランを必ず通す

**電源を強制的に落とすスクリプトを、いきなり本番投入してはいけません。** 検証せずに動かして作業を失うと、ツールごと捨てることになります。

2種類用意しました。

**通しリハーサル。** ステージを強制指定し、4段階を数秒間隔で流します。

```bash
sudo ./enddayd.sh rehearsal 5        # 5秒間隔で4段階
sudo ./enddayd.sh stage warn         # 単体で確認
```

18:30 相当のステージでは、ログアウトを実行する代わりに、そのとき起動中のGUIアプリ一覧をログに残します。本番で何が終了を拒否しそうかを事前に把握できます。あわせて「自動化」の許可の有無も出します。ログアウト試行は System Events への Apple Event なので許可が要り、無ければ毎回失敗しますが、設計上そこでは止まりません。**リハーサルで出しておかないと、失敗し続けていることに誰も気づけません。**

**実時間ドライラン。** `/etc/enddayd.dryrun` があるあいだは、実際の18:00 / 18:30 / 18:45 / 18:50 に本番と同じ通知・音・タイミングで動き、ログアウトと電源オフだけをスキップします。18:50には「本番ならここで落ちていた」とだけ表示されます。`install` は必ずこの状態で入るようにしてあり、明示的に切り替えるまで電源は落ちません。

```bash
sudo ./enddayd.sh dryrun on    # ドライラン
sudo ./enddayd.sh dryrun off   # 本番
sudo ./enddayd.sh status       # 現在どちらかを確認
```

数日これで回して、文言と時刻が自分に合っているかを確かめてから本番に切り替えるのが安全です。ついでに、ドライラン中のログは「自分が何時まで作業しているか」の記録にもなります。

## 一番まずい壊れ方は「効いていないことに気づかない」

このツールで最悪なのは、蓋を開けた瞬間に電源が落ちることではありません。**効いていないのに効いているつもりでいること**です。落ちれば嫌でも分かりますが、動いていないことは何も起きないので分かりません。

設定ファイルは手で編集できるようにしてあります。そこで壊れると、時間帯の判定が総崩れになって「何もしない」で終わり、しかもそれが `skip: out of window` という正常時とまったく同じログに見えます。だから読み込むたびに検証し、通らなければ**走らせません**。理由はログと画面の両方に出します。

```
設定エラー  : 直すまで終業は実行されません
  - TIMES は 予告,警告,最終通告,強制終了 の4つが必要です（いま 3 個）: TIMES="18:00,18:30,18:50"
```

止まって文句を言われるほうが、気づけない停止よりましだという判断です。同じ考えで、次のような経路も塞いであります。

- 構文エラーのある設定ファイルを素で `source` しない（代入だけ失敗して既定値のまま動く）
- plist は一時ファイルに書いて `plutil -lint` を通してから差し替える（生成に失敗して0バイトの plist が残ると、デーモンが黙って消える）
- 必須項目が欠けていたら既定値で補わずに拒否する（意図しない時刻で動く）
- 入れ直しでモードを勝手にドライランへ戻さない（更新のたびに黙って無効化される）

そして、本番で強制終了まで到達したらログに残し、`status` に「本番到達」として最後の日時を出します。導入した時点では効くかどうか分かりませんが、一度落ちたあとなら「少なくとも経路は生きている」と言えます。

## 既製アプリという選択肢

作る前に確認しておくと、この領域にはすでにアプリがあります。

Setapp の Almighty には Schedule Shutdown があり、カウントダウン形式で電源を落とせます。Setapp に入っているなら追加費用ゼロで試せます。買い切りなら Tension Software の Mac Shutdown が、アプリの拒否で中断されにくい「Hard Shutdown」と曜日指定の繰り返しを持っています。

自作したのは、段階的なエスカレーションと、逃げ道の摩擦設計が欲しかったからです。既製品はどれも「タイマーユーティリティ」として作られていて、「習慣を止める装置」としては設計されていません。ここは目的が違うので、要件が単に「決まった時刻に落ちてほしい」だけなら、素直に既製品を使うほうが早いです。

なお、この手のものをMac App Storeで配布するのは構造的に無理です。App Sandbox が権限昇格を禁じており、`SMJobBless` はサンドボックスアプリから使えたことがなく、App Store は同梱する特権実行ファイル自体のサンドボックス化を要求します。強制シャットダウンの核が root 権限である以上、Developer ID での直販しか道がありません。

## この仕組みが解決すること、しないこと

導入して分かったのは、**18:30の警告が出た時点で「今日はここまで」という判断が発生するようになる**ことです。裏を返すと、それまでは判断そのものが発生していませんでした。作業が延びていく状態には明確な始点がなくて、始点がないものは意志では止められません。外から始点を作る、というのがこの仕組みの実質です。

一方で、**電源を落としたからといって作業量が減るわけではありません。** 抱えている量が原因なら、18:50に落ちたぶんが翌朝に積み上がるだけです。この仕組みが解決するのは「区切りが分からなくなる」問題であって、「量が多い」問題ではありません。後者はスケジュールや見積もりの側で解く話で、シェルスクリプトの守備範囲ではないです。

ドライランのログには、どのアプリが動いていたか、何時のステージまで到達したかが残ります。自分がどちらの問題を抱えているのかを判断する材料になるので、本番に切り替える前に数日回してみることをおすすめします。

エージェントに任せられる範囲が広がるほど、1日に詰め込める量は増えます。増えた余白を全部作業で埋めるのか、早く終わるようになった結果として受け取るのかは、ツールの側では決めてくれません。その線引きだけは、自分で（あるいは自分で書いたシェルスクリプトで）決めるしかないと思っています。
