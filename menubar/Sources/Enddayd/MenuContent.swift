import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var model: DaemonModel
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @AppStorage("iconTint") private var tint: IconTint = .gold
    @AppStorage(Updater.modeKey) private var updateMode: UpdateCheck.Mode = .confirm

    var body: some View {
        Group {
            if let r = updater.available {
                Button(updater.busy ? "\(r.version)に更新しています…" : "\(r.version)に更新する（いまは\(Updater.currentVersion)）") {
                    updater.update()
                }
                .disabled(updater.busy)
                Divider()
            }
            statusSection
            Divider()
            if model.installed {
                actionSection
                Divider()
                logSection
                Divider()
            }
            // 強制終了で消えた端末の作業を開き直す。記録が無ければ出さない。
            // 本体を外した後でも、残った記録から開き直せるようにinstalledの外に置く
            if let snap = model.terminalSnapshot {
                Button("端末の作業を開き直す（\(TerminalSnapshot.label(snap))）") {
                    model.restoreTerminals()
                }
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
            if !model.extraEnforce.isEmpty {
                Text("強制終了の回: \(model.enforceListText)")
            }
            if !model.workLimit.isEmpty {
                Text("作業時間の上限: \(model.workLimit)（その日最初の操作から）")
            }
            if let deadline = model.timerDeadline {
                Text("タイマー: \(DaemonModel.timeFormatter.string(from: deadline)) に終了")
            }
            if !model.daemonLoaded {
                Text("常駐していません。「本体を修復する…」で戻ります")
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
                Button("\(model.extendTarget ?? "") の強制終了を \(minutes)分 延ばす") {
                    model.extendToday(minutes, target: model.extendTarget)
                }
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

        // 時刻ではなく長さで決める終了。今日だけの調整（緩める側）とは逆向きなので分けて置く。
        Menu("タイマーで終了する") {
            ForEach([15, 30, 60, 90, 120], id: \.self) { minutes in
                Button("今から \(minutes)分後") { model.startTimer(minutes) }
            }
            if model.timerDeadline != nil {
                Divider()
                Button("タイマーを取り消す") { model.cancelTimer() }
            }
        }
        .disabled(model.busy || !model.installed)

        Button("時刻・曜日・レベルを変更…") {
            openWindow(id: "schedule")
            NSApp.activate(ignoringOtherApps: true)
        }
        // 更新の取得中に開くと、置き換えて開き直すときに編集中の画面が閉じる
        .disabled(updater.busy)

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
            // 違いがあるなら更新、外れているだけなら修復。どちらもinstallで、モードと設定は保つ
            Button(model.updateAvailable ? "本体を更新する…" : "本体を修復する…") { confirmReinstall() }
                .disabled(model.busy)
        }

        // 見た目の好みなので、デーモンの設定とは別にこのアプリの中だけで持つ
        Picker("アイコンの色", selection: $tint) {
            ForEach(IconTint.allCases) { option in
                Text(option.label).tag(option)
            }
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
        Button(updater.checking ? "更新を確認しています…" : "更新を確認") { updater.check(manual: true) }
            .disabled(updater.busy || updater.checking)
        // 自動でも、強制終了の予告から強制終了までの間と、設定の画面を開いている間は更新しない
        Picker("更新の方法", selection: Binding(
            get: { updateMode },
            set: { updateMode = $0; updater.setMode($0) }
        )) {
            ForEach(UpdateCheck.Mode.allCases) { option in
                Text(option.label).tag(option)
            }
        }

        Divider()
        // デーモンはアプリと別に動くので、終了で何が止まるかを名前で示す
        Button(model.requireApp ? "終了（通知と強制終了も止まります）" : "終了（通知と強制終了は動き続けます）") {
            NSApplication.shared.terminate(nil)
        }
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
        let verb = model.updateAvailable ? "更新" : "修復"
        alert.messageText = "本体を\(verb)しますか？"
        let reason = model.updateAvailable
            ? "このアプリが持っている本体と、導入済みの本体が違います。"
            : "本体はありますが、常駐から外れています。"
        alert.informativeText = reason
            + "\(verb)しても、いまのモード（\(model.dryRun ? "停止中" : "本番")）と設定はそのままです。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "\(verb)する")
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
