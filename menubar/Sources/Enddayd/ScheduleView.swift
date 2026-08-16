import SwiftUI

/// 時刻・曜日・レベルの設定画面。
/// 保存すると /etc/enddayd.conf を書き換えて reload する（管理者パスワードが要る）。
struct ScheduleView: View {
    @EnvironmentObject var model: DaemonModel
    @Environment(\.dismiss) private var dismiss

    @State private var stageDates: [Date] = []
    @State private var days: Set<Int> = []
    @State private var level: EnforceLevel = .normal
    @State private var logout = true
    @State private var bypass = true
    @State private var grace = 10
    @State private var loaded = false

    private let stageLabels = ["予告（切り上げの合図）", "警告（実質の締切）", "最終通告", "強制終了"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            GroupBox("段階と時刻") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack {
                            Text(stageLabels[i])
                            Spacer()
                            if stageDates.count == 4 {
                                DatePicker("", selection: $stageDates[i], displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .frame(width: 90)
                            }
                        }
                    }
                }
                .padding(6)
            }

            GroupBox("曜日") {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(DaemonModel.weekdayName(d), isOn: dayBinding(d))
                            .toggleStyle(.button)
                    }
                }
                .padding(6)
            }

            GroupBox("強制終了のレベル") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $level) {
                        ForEach(EnforceLevel.allCases) { lv in
                            Text(lv.label).tag(lv)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if level == .hard {
                        Text("hard は編集中のファイルを保存せずに落とします。")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(6)
            }

            GroupBox("細かい挙動") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("警告の段階でログアウトを試みる", isOn: $logout)
                    Toggle("当日スキップ（/etc/enddayd.skip）を許す", isOn: $bypass)
                    Stepper("最終段階を受け付ける猶予: \(grace) 分", value: $grace, in: 0...120)
                }
                .padding(6)
            }

            if let problem = validationMessage {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            // 保存はできるが、書いたとおりには効かないもの。
            // 判定はデーモンと共通の ConfParser に置いてある。
            ForEach(warningMessages, id: \.self) { warning in
                Text("注意: \(warning)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(model.dryRun
                     ? "いまは停止中です。保存しても電源は落ちません。"
                     : "本番で動いています。保存するとこの内容で終了します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }
                Button("保存して反映") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil || model.busy)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { loadFromModel() }
        // 閉じたら読み込み済みの印を外す。外さないと、閉じているあいだに
        // 設定が変わっても次に開いたとき古い値のままになる。
        .onDisappear { loaded = false }
    }

    // ------------------------------------------------------------ 入出力 ---

    private func loadFromModel() {
        guard !loaded else { return }
        loaded = true
        stageDates = model.times.map { t in
            let (h, m) = DaemonModel.parseTime(t) ?? (18, 0)
            return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
        days = model.weekdays
        level = model.level
        logout = model.logoutAttempt
        bypass = model.allowBypass
        grace = model.killGrace
    }

    private func dayBinding(_ d: Int) -> Binding<Bool> {
        Binding(
            get: { days.contains(d) },
            set: { on in
                if on { days.insert(d) } else { days.remove(d) }
            }
        )
    }

    private var timeStrings: [String] {
        stageDates.map { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
    }

    private var validationMessage: String? {
        guard stageDates.count == 4 else { return nil }
        if days.isEmpty { return "曜日を1つ以上選んでください" }
        let mins = stageDates.map { d -> Int in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        for i in 1..<4 where mins[i] <= mins[i - 1] {
            return "時刻は早い順に並べてください（\(stageLabels[i]) が前の段階より早いか同時刻です）"
        }
        return nil
    }

    /// 保存を止めない注意書き。止めてしまうと、その日から強制終了ごと
    /// 効かなくなるほうが害が大きい。
    private var warningMessages: [String] {
        guard validationMessage == nil, stageDates.count == 4 else { return [] }
        var provisional = ConfState()
        provisional.times = timeStrings
        provisional.weekdays = days
        provisional.level = level
        provisional.logoutAttempt = logout
        provisional.allowBypass = bypass
        provisional.killGrace = grace
        return ConfParser.warnings(for: provisional)
    }

    private func save() {
        model.saveConfig(times: timeStrings, weekdays: days, level: level,
                         logout: logout, bypass: bypass, grace: grace)
        dismiss()
    }
}
