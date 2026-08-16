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
            // 「壊れています」だけだと直しようがない。デーモンが拒否している
            // 理由をそのまま出す（判定の規則はデーモン側と揃えてある）。
            ForEach(model.confProblems.prefix(3), id: \.self) { problem in
                Text("・\(problem)")
            }
        } else {
            let days = model.weekdays.sorted().map(DaemonModel.weekdayName).joined()
            Text("\(days) \(model.times[0]) 予告 → \(model.times[3]) 終了（\(model.level.rawValue)）")
            if !model.daemonLoaded {
                Text("常駐していません。「本体を入れ直す」で復帰します")
            } else if model.dryRun {
                Text("いまは停止中（通知のみ・電源は落ちません）")
            } else if let next = model.nextEnforceDate() {
                Text("次の強制終了: \(Self.relative(next))")
            }
            if model.skipToday {
                Text("今日はスキップ指定があります")
            }
            if model.today.isActive {
                Text("今日だけ: \(model.today.summary)（明日には戻ります）")
            }
            ForEach(model.confWarnings, id: \.self) { warning in
                Text("注意: \(warning)")
            }
            // 効いているかどうかの手がかり。本番で一度も落ちていなければ
            // 経路が生きているかは分からない（enddayd.sh の status と同じ）。
            if let reached = model.lastEnforce {
                Text("最後に本番で実行: \(reached)")
            } else if !model.dryRun {
                Text("本番ではまだ一度も実行されていません")
            }
            if model.logoutAttempt && model.automation == .denied {
                Text("「自動化」の許可がありません。警告時のログアウトは失敗します")
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

        // 今日だけの調整。恒久的な設定変更とは別の場所に置く。
        // 同じ場所に混ぜると「今日だけのつもりが毎日変わった」が起きる。
        Menu("今日だけ調整する") {
            ForEach(model.allowedExtendSlots, id: \.self) { minutes in
                Button("強制終了を \(minutes)分 延ばす") { model.extendToday(minutes) }
            }
            Divider()
            Button("今日はレベルを notify にする（落とさない）") { model.setTodayLevel(.notify) }
            Button("今日はレベルを soft にする（拒否できる）") { model.setTodayLevel(.soft) }
            if model.today.isActive {
                Divider()
                Button("今日の調整を取り消す") { model.clearToday() }
            }
        }
        .disabled(model.busy)

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
        } else if model.updateAvailable || !model.daemonLoaded {
            // アプリを新しくしても、導入済みの本体は勝手には入れ替わらない。
            // 出口が無いと古いまま動き続けるので、違いが出たら導線を出す。
            Button("本体を入れ直す…") { confirmReinstall() }
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

        // 版を出しておく。出ていないと「入れ直したのに古いままでは」を
        // 確かめる手段が無く、動作の報告と実際の版が結び付かない。
        Text("バージョン \(Self.appVersion)")

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

    private func confirmReinstall() {
        let alert = NSAlert()
        alert.messageText = "本体を入れ直しますか？"
        let reason = model.daemonLoaded
            ? "このアプリが持っている本体と、導入済みの本体が違います。"
            : "本体はありますが、常駐から外れています。"
        alert.informativeText = reason
            + "入れ直しても、いまのモード（\(model.dryRun ? "停止中" : "本番")）と設定はそのままです。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "入れ直す")
        alert.addButton(withTitle: "やめておく")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.install()
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

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil):    return short
        default:                   return "不明"
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
