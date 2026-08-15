import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var model: DaemonModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusSection
            Divider()
            if model.installed {
                actionSection
                Divider()
                logSection
                Divider()
            }
            manageSection
        }
        .onAppear { model.refresh() }
    }

    // ------------------------------------------------------------ 状態 ---

    @ViewBuilder
    private var statusSection: some View {
        if !model.installed {
            Text("未導入（常駐していません）")
        } else if model.confBroken {
            Text("設定が壊れています。直すまで終業は実行されません")
        } else {
            let days = model.weekdays.sorted().map(DaemonModel.weekdayName).joined()
            Text("\(days) \(model.times[0]) 予告 → \(model.times[3]) 終了（\(model.level.rawValue)）")
            if model.dryRun {
                Text("いまは停止中（通知のみ・電源は落ちません）")
            } else if let next = model.nextEnforceDate() {
                Text("次の強制終了: \(Self.relative(next))")
            }
            if model.skipToday {
                Text("今日はスキップ指定があります")
            }
        }
        if let err = model.lastError {
            Text("エラー: \(err)")
        }
    }

    // ------------------------------------------------------------ 操作 ---

    @ViewBuilder
    private var actionSection: some View {
        if model.dryRun {
            Button("動かす（本番に切り替える）…") { confirmResume() }
        } else {
            Button("止める（電源を落とさなくする）") { model.pause() }
        }

        if model.skipToday {
            Button("今日のスキップを取り消す") { model.skipTodayOff() }
        } else {
            Button("今日はスキップ") { model.skipTodayOn() }
        }

        Button("時刻・曜日・レベルを変更…") {
            openWindow(id: "schedule")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("通しで確認（リハーサル）") { model.rehearsal() }
            .disabled(model.busy)
    }

    // ------------------------------------------------------------ ログ ---

    @ViewBuilder
    private var logSection: some View {
        if model.logTail.isEmpty {
            Text("ログはまだありません")
        } else {
            ForEach(model.logTail, id: \.self) { line in
                Text(line)
            }
        }
    }

    // ------------------------------------------------------------ 管理 ---

    @ViewBuilder
    private var manageSection: some View {
        if !model.installed {
            Button("導入する…") { model.install() }
                .disabled(model.busy)
        }

        Toggle("ログイン時に起動", isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        if model.installed {
            Button("すべて削除（アンインストール）…") { confirmUninstall() }
                .disabled(model.busy)
        }

        Button("GitHub で見る") {
            if let url = URL(string: "https://github.com/BoxPistols/enddayd") {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }
    }

    // ------------------------------------------------------------ 確認 ---

    private func confirmResume() {
        let alert = NSAlert()
        alert.messageText = "本番に切り替えますか？"
        let next = model.nextEnforceDate().map(Self.relative) ?? "設定した時刻"
        alert.informativeText = "次の強制終了は \(next) です。レベル \(model.level.rawValue) で、アプリの拒否権なしに電源が落ちます。いつでも「止める」で戻せます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "本番に切り替える")
        alert.addButton(withTitle: "やめておく")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.resume()
        }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "enddayd を削除しますか？"
        alert.informativeText = "常駐を外し、本体と起動設定を削除します。設定ファイルとログは残ります。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除する")
        alert.addButton(withTitle: "やめておく")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.uninstall()
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "今日 H:mm"
        } else if Calendar.current.isDateInTomorrow(date) {
            f.dateFormat = "明日 H:mm"
        } else {
            f.dateFormat = "E曜 H:mm"
        }
        return f.string(from: date)
    }
}
