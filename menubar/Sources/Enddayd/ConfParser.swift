import Foundation

/// `/etc/enddayd.conf` を読んだ結果。
///
/// 検証の規則はデーモン側（`enddayd.sh` の `validate_conf`）と揃えてある。
/// ここが緩いと「GUI では正常に見えるのにデーモンは走らない」という、
/// 一番たちの悪い食い違いになる。規則を変えるときは必ず両方を直すこと。
///
/// 表示のためだけの型で、副作用も権限も持たない。テストは `tests/ConfParserTests.swift`。
struct ConfState: Equatable {
    var times: [String] = ["18:00", "18:30", "18:45", "18:50"]
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]   // 1=月 … 7=日
    var level: EnforceLevel = .normal
    var logoutAttempt = true
    var allowBypass = true
    var killGrace = 10
    /// 追加の強制終了（EXTRA_ENFORCE）。TIMES の4つ目とは別に、その日に落とす時刻。
    var extraEnforce: [String] = []
    /// 作業開始からの上限（WORK_LIMIT）。書かれた形のまま持つ。空なら無し。
    var workLimit = ""

    /// 検証を通らなかった理由。空でなければデーモンは走らない。
    var problems: [String] = []

    var isBroken: Bool { !problems.isEmpty }
}

enum ConfParser {

    /// 設定ファイルの中身から状態を組み立てる。
    ///
    /// 妥当でない項目は既定値のままにし、理由を `problems` に積む。既定値で
    /// 補って正常に見せると、利用者の意図と違う時刻で動いていることに
    /// 気づけない（デーモン側も同じ理由で必須項目の欠落を拒否する）。
    static func parse(_ text: String) -> ConfState {
        var state = ConfState()
        var problems: [String] = []
        let dict = keyValues(text)

        for key in ["TIMES", "WEEKDAYS", "LEVEL"] where dict[key] == nil {
            problems.append("\(key) が設定ファイルにありません")
        }

        if let raw = dict["TIMES"] {
            let parts = raw.split(separator: ",").map(String.init)
            let minutes = parts.compactMap(minutes(of:))
            if parts.count != 4 {
                problems.append("TIMES は 予告,警告,最終通告,強制終了 の4つが必要です（いま \(parts.count) 個）")
            } else if minutes.count != 4 {
                problems.append("TIMES に HH:MM でない値があります: \(raw)")
            } else if !zip(minutes, minutes.dropFirst()).allSatisfy({ $0 < $1 }) {
                problems.append("TIMES は早い順に並べてください: \(raw)")
            } else {
                state.times = parts
            }
        }

        if let raw = dict["WEEKDAYS"] {
            let fields = raw.split(separator: ",").map(String.init)
            let numbers = fields.compactMap { Int($0) }
            if fields.isEmpty {
                problems.append("WEEKDAYS が空です（1=月 … 7=日 をカンマ区切りで）")
            } else if fields.count != numbers.count || !numbers.allSatisfy({ (1...7).contains($0) }) {
                problems.append("WEEKDAYS は 1〜7 の数字で指定してください: \(raw)")
            } else {
                state.weekdays = Set(numbers)
            }
        }

        if let raw = dict["LEVEL"] {
            if let level = EnforceLevel(rawValue: raw) {
                state.level = level
            } else {
                problems.append("LEVEL は notify / soft / normal / hard のいずれかです: \(raw)")
            }
        }

        if let raw = dict["KILL_GRACE"] {
            if let n = Int(raw), n >= 0 {
                state.killGrace = n
            } else {
                problems.append("KILL_GRACE は 0 以上の整数（分）です: \(raw)")
            }
        }

        if let raw = dict["LOGOUT_ATTEMPT"] {
            if let flag = boolFlag(raw) {
                state.logoutAttempt = flag
            } else {
                problems.append("LOGOUT_ATTEMPT は 0 か 1 です: \(raw)")
            }
        }

        if let raw = dict["ALLOW_BYPASS"] {
            if let flag = boolFlag(raw) {
                state.allowBypass = flag
            } else {
                problems.append("ALLOW_BYPASS は 0 か 1 です: \(raw)")
            }
        }

        if let raw = dict["WORK_LIMIT"], !raw.isEmpty {
            if workLimitMinutes(raw) != nil {
                state.workLimit = raw
            } else {
                problems.append("WORK_LIMIT は 時間（\"8\"）か 時間:分（\"7:30\"）で、1分〜23:59 の範囲です: \(raw)")
            }
        }

        if let raw = dict["EXTRA_ENFORCE"], !raw.isEmpty {
            // bash の `IFS=, read -a` と同じく、末尾の空要素だけは捨てる
            var parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            if let bad = parts.first(where: { minutes(of: $0) == nil }) {
                problems.append("EXTRA_ENFORCE の \"\(bad)\" が HH:MM ではありません: \(raw)")
            } else {
                state.extraEnforce = parts
                // 回どうしの重なりは TIMES と猶予が読めたときだけ見る（デーモンと同じ）
                if problems.isEmpty, let problem = sessionProblem(state) {
                    problems.append(problem)
                }
            }
        }

        state.problems = problems
        return state
    }

    // ------------------------------------------------------- 1日の回 ---

    /// 1回ぶんの時刻（0:00 からの分）。予告・警告・最終通告は TIMES と同じ間隔で前に付く。
    struct Session: Equatable {
        let notice: Int
        let warn: Int
        let final: Int
        let enforce: Int
    }

    /// その日の回を強制終了の早い順に並べる。enddayd.sh の build_sessions と同じ組み立て。
    static func sessions(_ state: ConfState) -> [Session] {
        let m = state.times.compactMap(minutes(of:))
        guard m.count == 4 else { return [] }
        let enforces = ([m[3]] + state.extraEnforce.compactMap(minutes(of:))).sorted()
        return enforces.map {
            Session(notice: $0 - (m[3] - m[0]), warn: $0 - (m[3] - m[1]),
                    final: $0 - (m[3] - m[2]), enforce: $0)
        }
    }

    /// 回どうしが重なる・前日にはみ出す設定を断る。enddayd.sh の validate_extras と同じ規則。
    static func sessionProblem(_ state: ConfState) -> String? {
        let all = ([state.times[3]] + state.extraEnforce).compactMap(minutes(of:))
        if Set(all).count != all.count {
            return "強制終了の時刻が重複しています（EXTRA_ENFORCE=\(state.extraEnforce.joined(separator: ","))）"
        }
        let list = sessions(state)
        for (i, s) in list.enumerated() {
            if s.notice < 0 {
                return "\(hhmm(s.enforce)) の予告（\(s.enforce - s.notice)分前）が 0:00 より前になります。もっと遅い時刻にしてください"
            }
            if i > 0, list[i - 1].enforce + state.killGrace >= s.notice {
                return "\(hhmm(list[i - 1].enforce)) の猶予（\(state.killGrace)分）と \(hhmm(s.enforce)) の予告（\(hhmm(s.notice))）が重なります。間を空けてください"
            }
        }
        return nil
    }

    /// 回を足すときの初期値。12:00から1時間刻みで、足してもsessionProblemに
    /// 掛からない最初の正時を返す（12〜23時のあと1〜11時）。無ければnil。
    /// 文字列が重ならないだけで選ぶと、既定の設定では2回目から必ず猶予と予告が重なる。
    static func nextFreeEnforce(_ state: ConfState) -> String? {
        for hour in Array(12...23) + Array(1...11) {
            var trial = state
            trial.extraEnforce.append(String(format: "%02d:00", hour))
            if sessionProblem(trial) == nil { return String(format: "%02d:00", hour) }
        }
        return nil
    }

    /// WORK_LIMIT を分に直す。"8" / "7:30" の形で 1〜1439 分。enddayd.sh の work_limit_min と同じ。
    static func workLimitMinutes(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        let isDigits: (Substring) -> Bool = { part in
            !part.isEmpty && part.allSatisfy { ch in ch.isASCII && ch.isNumber }
        }
        guard parts.allSatisfy(isDigits) else { return nil }
        let total: Int
        switch parts.count {
        case 1:
            guard parts[0].count <= 2, let h = Int(parts[0]) else { return nil }
            total = h * 60
        case 2:
            guard parts[0].count <= 2, parts[1].count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]), m <= 59 else { return nil }
            total = h * 60 + m
        default:
            return nil
        }
        return (1...(24 * 60 - 1)).contains(total) ? total : nil
    }

    static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// 走ることは走るが、設定が書いたとおりには効かないもの。
    /// 拒否するとその日から強制終了ごと止まってしまうので、警告に留める。
    static func warnings(for state: ConfState) -> [String] {
        guard !state.isBroken,
              state.times.count == 4,
              let last = sessions(state).last?.enforce else { return [] }   // その日最後の回

        var out: [String] = []
        let endOfDay = 24 * 60 - 1
        if last + state.killGrace > endOfDay {
            out.append("猶予が日をまたぎます。\(hhmm(last)) から \(state.killGrace) 分は 23:59 で切れるので、"
                       + "実際に受け付けるのは \(endOfDay - last) 分です")
        }
        return out
    }

    // ------------------------------------------------------------ 補助 ---

    /// `KEY="VALUE"` の行を拾う。CR 単独・CRLF の改行も区切りとして扱う。
    ///
    /// 区切りは `isNewline` で見る。`$0 == "\n" || $0 == "\r"` と書くと CRLF を
    /// 取りこぼす。Swift の Character は書記素クラスタなので、CRLF は
    /// 2 文字ではなく 1 文字で、どちらとも一致しない。
    static func keyValues(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !key.isEmpty else { continue }
            dict[key] = value
        }
        return dict
    }

    static func minutes(of time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func boolFlag(_ raw: String) -> Bool? {
        switch raw {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
}
