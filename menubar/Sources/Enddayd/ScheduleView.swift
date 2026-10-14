import SwiftUI

/// 曜日の入切。
///
/// 素の `.toggleStyle(.button)` に任せると、入と切の差がグレーの 216 と 228
/// （差 4.7%）にしかならず、どの曜日が有効かを一目で読めない。`.tint` を足しても
/// 変わらなかった。この画面で一番大事な設定なので、フレームワークの選択表現に
/// 頼らず、地の色・文字色・枠の3つで自分で分ける。
///
/// Toggle のまま包んでいるのは、支援技術に「入切できるもの」として伝えるため。
private struct DayToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.body)
                .frame(width: 32, height: 24)
                .foregroundStyle(configuration.isOn ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor),
                                lineWidth: configuration.isOn ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

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
    @State private var requireApp = false
    @State private var grace = 10
    /// 画面に並べる回。基準の回（TIMES）と追加の回（EXTRA_ENFORCE）を、強制終了の
    /// 早い順に並べる。番号をデーモンやメニューの回の順と揃えるため、時刻を動かして
    /// 順が入れ替わったらその場で並べ直す。
    @State private var slots: [Slot] = []
    /// 開いた時点の設定。開いているあいだに外で書き換えられたら保存を止める
    /// （画面の値で上書きすると、外で足した回が黙って消える）。
    @State private var loadedConf: ConfState?
    /// 回の一覧の中身の高さ。一覧だけを高さの上限つきでスクロールさせるのに使う。
    @State private var slotsHeight: CGFloat = 0
    /// 一覧の高さの上限。回を足すたびに窓が伸びて、保存ボタンが画面の外に出ないようにする。
    private let slotsMaxHeight: CGFloat = 380

    private struct Slot: Identifiable {
        let id = UUID()
        /// 基準の回は4段階をstageDatesで持つ。追加の回は強制終了の時刻だけを持つ。
        let isBase: Bool
        var enforce: Date
    }
    @State private var loaded = false

    private let stageLabels = ["予告（切り上げの合図）", "警告（実質の締切）", "最終通告", "強制終了"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // 設定ファイルが読めないと、読めなかった項目は既定値のまま画面に出る。
            // そのまま保存すると手で書いた値が消えるので、理由を先に見せる
            if !model.confProblems.isEmpty {
                Text("設定ファイルに読めない値があります。保存すると画面の内容で書き直します: \(model.confProblems.joined(separator: " / "))")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("強制終了の回") {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(slots.enumerated()), id: \.element.id) { n, slot in
                                if n > 0 { Divider() }
                                slotView(slot, number: n + 1)
                            }
                        }
                        .padding(.trailing, slotsHeight > slotsMaxHeight ? 12 : 0)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: SlotsHeightKey.self, value: g.size.height)
                        })
                    }
                    .frame(height: min(slotsHeight, slotsMaxHeight))
                    .onPreferenceChange(SlotsHeightKey.self) { slotsHeight = $0 }

                    // 説明とボタンを同じ行に並べると説明が2行に折り返して潰れる（下の保存ボタンと同じ理由）
                    Text("追加した回の予告・警告・最終通告は、基準の回と同じ間隔で前に付きます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("回を足す") { addSlot() }
                            .disabled(stageDates.count != 4 || ConfParser.nextFreeEnforce(provisionalState) == nil)
                            .help("足しても他の回と重ならない時刻が入ります")
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("曜日") {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(DaemonModel.weekdayName(d), isOn: dayBinding(d))
                            .toggleStyle(DayToggleStyle())
                            .help(days.contains(d) ? "この曜日は有効" : "この曜日は対象外")
                    }
                    Spacer()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("細かい挙動") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("警告の段階でログアウトを試みる", isOn: $logout)
                    Toggle("当日スキップを許す", isOn: $bypass)
                        .help("date +%F > /etc/enddayd.skip でその日だけ見送れるようにする")
                    Stepper("最終段階を受け付ける猶予: \(grace) 分", value: $grace, in: 0...120)
                    Toggle("アプリを終了したら、通知と強制終了も止める", isOn: $requireApp)
                        .help("オフなら、アプリを終了してもデーモンが通知と強制終了を続けます")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            // 説明とボタンを同じ行に並べると、幅が足りず説明が2行に折り返して
            // ボタンの脇で潰れる。行を分けてボタンだけを右に寄せる。
            VStack(alignment: .leading, spacing: 10) {
                Text(model.dryRun
                     ? "いまは停止中です。保存しても電源は落ちません。"
                     : "本番で動いています。保存するとこの内容で終了します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Spacer()
                    Button("閉じる") { dismiss() }
                    Button("保存して反映") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationMessage != nil || model.busy)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { loadFromModel() }
        .onChange(of: stageDates) { sortSlots() }
        // 閉じたら読み込み済みの印を外す。外さないと、閉じているあいだに
        // 設定が変わっても次に開いたとき古い値のままになる。
        .onDisappear { loaded = false }
    }

    // ------------------------------------------------------------ 入出力 ---

    private func loadFromModel() {
        guard !loaded else { return }
        loaded = true
        loadedConf = model.conf
        stageDates = model.times.map(dateOf)
        slots = [Slot(isBase: true, enforce: Date())]
            + model.extraEnforce.map { Slot(isBase: false, enforce: dateOf($0)) }
        sortSlots()
        days = model.weekdays
        level = model.level
        logout = model.logoutAttempt
        bypass = model.allowBypass
        requireApp = model.requireApp
        grace = model.killGrace
    }

    private func dateOf(_ t: String) -> Date {
        let (h, m) = DaemonModel.parseTime(t) ?? (18, 0)
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    /// 回の見出しと中身。基準の回は4段階を選び、追加の回は強制終了だけを選ぶ。
    @ViewBuilder
    private func slotView(_ slot: Slot, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot.isBase ? "\(number)回目（基準）" : "\(number)回目")
                    .font(.headline)
                Spacer()
                if !slot.isBase {
                    Button("削除") { slots.removeAll { $0.id == slot.id } }
                        .accessibilityLabel("\(number)回目を削除")
                }
            }
            if slot.isBase {
                ForEach(0..<4, id: \.self) { i in
                    HStack {
                        Text(stageLabels[i])
                        Spacer()
                        if stageDates.count == 4 {
                            DatePicker("", selection: $stageDates[i], displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .frame(width: 90)
                                .accessibilityLabel("\(number)回目の\(stageLabels[i])")
                        }
                    }
                }
            } else {
                HStack {
                    Text(stageLabels[3])
                    Spacer()
                    DatePicker("", selection: enforceBinding(slot.id), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 90)
                        .accessibilityLabel("\(number)回目の強制終了")
                }
                Text(derivedStages(slot.enforce))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 追加の回の予告・警告・最終通告。組み立てはデーモンと共通のConfParser.sessionsに任せる。
    private func derivedStages(_ enforce: Date) -> String {
        guard stageDates.count == 4 else { return "" }
        let end = DaemonModel.minuteOfDay(enforce)
        guard let session = ConfParser.sessions(provisionalState).first(where: { $0.enforce == end }) else { return "" }
        // 基準の段階の順が崩れている編集途中は、計算した時刻が意味を持たない（赤字で保存も止まる）
        let base = stageDates.map(DaemonModel.minuteOfDay)
        guard zip(base, base.dropFirst()).allSatisfy({ $0 < $1 }) else { return "" }
        // 0:00より前にはみ出す設定はvalidationMessageが止める。ここでは見せ方だけ揃える
        let label: (String, Int) -> String = { name, m in m < 0 ? "\(name)前日" : name + ConfParser.hhmm(m) }
        return [label("予告", session.notice), label("警告", session.warn), label("最終通告", session.final)]
            .joined(separator: " / ")
    }

    /// 削除した直後、消えたまとまりのDatePickerが読みに来ることがあるので、idで引いて無ければ触らない。
    private func enforceBinding(_ id: UUID) -> Binding<Date> {
        Binding(
            get: { slots.first { $0.id == id }?.enforce ?? Date() },
            set: { v in
                if let k = slots.firstIndex(where: { $0.id == id }) { slots[k].enforce = v }
                sortSlots()
            }
        )
    }

    private func enforceDate(_ slot: Slot) -> Date {
        slot.isBase && stageDates.count == 4 ? stageDates[3] : slot.enforce
    }

    private func sortSlots() {
        slots.sort { DaemonModel.minuteOfDay(enforceDate($0)) < DaemonModel.minuteOfDay(enforceDate($1)) }
    }

    /// 足した回の初期値は、足しても重ならない正時（ConfParser.nextFreeEnforce）。
    private func addSlot() {
        guard let time = ConfParser.nextFreeEnforce(provisionalState) else { return }
        slots.append(Slot(isBase: false, enforce: dateOf(time)))
        sortSlots()
    }

    private func dayBinding(_ d: Int) -> Binding<Bool> {
        Binding(
            get: { days.contains(d) },
            set: { on in
                if on { days.insert(d) } else { days.remove(d) }
            }
        )
    }

    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private var timeStrings: [String] { stageDates.map(Self.hhmm) }

    /// 早い順。設定ファイルにもこの順で書く。
    private var extraTimeStrings: [String] {
        slots.filter { !$0.isBase }.map { Self.hhmm($0.enforce) }.sorted()
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
        if let opened = loadedConf, opened != model.conf {
            return "開いているあいだに設定ファイルが変わりました。閉じて開き直してください"
        }
        // 回どうしの重なりはデーモンのreloadでも断られる。保存前に同じ規則で止める
        return ConfParser.sessionProblem(provisionalState)
    }

    private var provisionalState: ConfState {
        var state = ConfState()
        state.times = timeStrings
        state.weekdays = days
        state.level = level
        state.logoutAttempt = logout
        state.allowBypass = bypass
        state.requireApp = requireApp
        state.killGrace = grace
        state.extraEnforce = extraTimeStrings
        return state
    }

    /// 保存を止めない注意書き。止めてしまうと、その日から強制終了ごと
    /// 効かなくなるほうが害が大きい。
    private var warningMessages: [String] {
        guard validationMessage == nil, stageDates.count == 4 else { return [] }
        var warnings = ConfParser.warnings(for: provisionalState)
        // 古い本体は新しい項目（EXTRA_ENFORCE・REQUIRE_APP）を読まない。保存で入れ直すことを先に伝える
        if model.updateAvailable {
            warnings.append("導入済みの本体がこのアプリと違うので、保存すると本体も入れ直します")
        }
        // 再起動後にアプリが起動しないと、その日は何も起きない
        if requireApp && !model.launchesAtLogin {
            warnings.append("「ログイン時に起動」がオフです。再起動後にアプリを開くまで、通知も強制終了も止まったままになります")
        }
        return warnings
    }

    private func save() {
        model.saveConfig(times: timeStrings, weekdays: days, level: level,
                         logout: logout, bypass: bypass, grace: grace,
                         extraEnforce: extraTimeStrings, requireApp: requireApp)
        dismiss()
    }
}

private struct SlotsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
