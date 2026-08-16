# 実機で1回だけ確認すること

`docs/known-issues.md` に残っている「実機でしか確認できない」3件を、1回の実施で片付けるための手順。
テストでもドライランでも届かない範囲なので、**実際に電源を落とすところまで通す**。

対象:

| 課題 | 確認すること |
| --- | --- |
| 自動化の許可 | 許可ダイアログが GUI ユーザーにちゃんと出るか。出ないまま失敗し続けないか |
| 本番で本当に落ちるか | `shutdown -h now` が実際に通るか |
| 猶予の内側で再起動 | 落ちた直後に電源を入れると、取りこぼし分が流れてまた落ちるか |

## 先に読む

**この手順の途中で Mac の電源が落ちる。** 保存していない作業はすべて失われる。実施前に:

- 編集中のものをすべて保存して閉じる
- 長時間かかる処理（ビルド、アップロード、バックアップ）を止める
- 30分ほど中断できる時間帯を選ぶ

**逃げ道は常にある。** どの段階でも次のコマンドで止まる。強制終了の10秒前にアラートが出るので、その間に打てる。

```bash
sudo touch /etc/enddayd.dryrun
```

## 手順

### 0. 準備

いま本番かドライランかを確かめ、ログを退避しておく（この確認のログだけを見たいので）。

```bash
sudo /usr/local/bin/enddayd.sh status
sudo cp /var/log/enddayd.log /var/log/enddayd.log.before-verify
```

ついでに、置いたローテーション設定が `newsyslog` に受理されるかを見る。**`-n` は
ドライランなので何も回さないが、root でないと実行できない**ため、テストからは確認できない。

```bash
sudo newsyslog -n -v -f /etc/newsyslog.d/enddayd.conf
```

`/var/log/enddayd.log` と `/var/log/enddayd.err.log` の 2 行が出て、それぞれ
「does not need trimming」等の判定が付けば読めている。`malformed line` のような
指摘が出たら書式が違うので `write_newsyslog` を直す。

### 1. 自動化の許可

まず**許可を与えていない状態**で警告段階だけを流す。既に許可済みなら、システム設定 → プライバシーとセキュリティ → 自動化 で `enddayd`（または呼び出し元として表示されるもの）のチェックを外してから始める。

```bash
sudo /usr/local/bin/enddayd.sh stage warn
```

見るところ:

- 画面に許可を求めるダイアログが**出るか**。root の LaunchDaemon から `launchctl asuser` 経由で叩いたときに GUI ユーザーへ出るのかが未確認の点
- 出た場合、そこで許可すると `automation ok` に変わるか
- 出ないまま失敗した場合、ログが `automation denied` になっているか（**なっていなければ検出そのものが効いていない**。`osascript` が許可なしでも 0 を返している可能性がある）

記録すること: ダイアログの有無、出た場合の文言、許可後に `automation ok` へ変わったか。

### 2. 本番で1回落とす

強制終了の時刻を数分後に設定し、本番へ切り替える。

```bash
sudo /usr/local/bin/enddayd.sh setup      # 予告/警告/最終通告/強制終了 を数分刻みで
sudo /usr/local/bin/enddayd.sh dryrun off
sudo /usr/local/bin/enddayd.sh config     # モードが「本番」になっていること
```

そのまま待つ。見るところ:

- 各段階のアラートが出るか
- 強制終了の10秒前に理由のアラートが出るか
- **実際に電源が落ちるか**

落ちなかった場合は、電源を入れてから `sudo /usr/local/bin/enddayd.sh status` を見る。「本番到達」に日時が入っていれば、スクリプトは `shutdown` まで到達している（落ちない原因はその先にある）。空のままなら、そもそも `run` が発火していない。

### 3. 猶予の内側で再起動

**手順2で落ちた直後、すぐに電源を入れる**（既定の猶予は10分なので、その内側で立ち上げる）。

見るところ:

- もう一度落ちるか。落ちれば「launchd が取りこぼし分を復帰時に流す」ということ
- 落ちなければ、そのまま使ってよい

**落ちた場合**、猶予（既定10分）を過ぎてから起動すれば必ず通常どおり立ち上がる。時間帯の判定は実行時の時計で行うので、窓を出てしまえば何も起きない。急ぐなら起動直後の10秒間に `sudo touch /etc/enddayd.dryrun` を打つ。

## 終わったら

設定を元に戻す。

```bash
sudo /usr/local/bin/enddayd.sh setup      # 普段の時刻に戻す
sudo /usr/local/bin/enddayd.sh status
```

結果を `docs/known-issues.md` に反映する。確認できた項目は消し、**確認して問題が見つかった項目は「未確認」から「未対応」に書き換える**（確認したこと自体が成果なので、消してしまわない）。

ログは `/var/log/enddayd.log.before-verify` に退避してあるので、必要なら突き合わせる。
