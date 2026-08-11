# Windows でやる場合（参考）

このリポジトリは macOS 向けです。実装は提供していませんが、同じ設計をWindowsに移すなら以下が対応します。

## 対応表

| macOS | Windows |
| --- | --- |
| LaunchDaemon の `StartCalendarInterval` | タスクスケジューラの週次トリガ（SYSTEM 実行） |
| `/sbin/shutdown -h now` | `shutdown.exe /s /f /t 0` |
| `launchctl bootout gui/$UID`（hard） | `logoff.exe <SessionId>` |
| `osascript display alert` | PowerShell のトースト通知、または `msg.exe *` |
| スリープ復帰時の遅延実行 | 「スケジュールされた開始時刻を過ぎたらタスクを開始する」オプション |

## 注意点

**`/f` は macOS の hard 相当です。** 保存確認を出さずにアプリを閉じます。`normal` 相当の穏当な選択肢は Windows にはあまりありません。

**`shutdown /s /f /t 300 /c "メッセージ"` を使うと、OS標準のカウントダウンが出ます。** 段階警告の一部をOSに任せられますが、`shutdown /a` で中断できてしまいます。回避可能な仕組みは回避したい日に回避されるので、この設計とは相性がよくありません。

**`msg.exe` は Home エディションに含まれません。** 通知は PowerShell 側で出す必要があります。

**ステージ判定は移植したほうがいいです。** タスクスケジューラの「開始時刻を過ぎたら実行」も、スリープ復帰時に同じ誤爆を起こします。実行時の時計を見てステージを決める方式はそのまま有効です。

## WSL2 は向きません

ゲストから `shutdown.exe /s /f` を interop で呼べばホストは落とせます。問題はスケジューラのほうです。WSL のインスタンスはアイドル時に自動停止するため、ターミナルを閉じていれば cron も systemd timer も止まっています。指定時刻に発火する保証がありません。

常時起動させる回避策はありますが、確実性のために常駐を増やすのは目的から外れます。Windows でやるならタスクスケジューラを直接使ってください。
