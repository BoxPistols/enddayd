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

        state.problems = problems
        return state
    }

    /// 走ることは走るが、設定が書いたとおりには効かないもの。
    /// 拒否するとその日から強制終了ごと止まってしまうので、警告に留める。
    static func warnings(for state: ConfState) -> [String] {
        guard !state.isBroken,
              state.times.count == 4,
              let last = minutes(of: state.times[3]) else { return [] }

        var out: [String] = []
        let endOfDay = 24 * 60 - 1
        if last + state.killGrace > endOfDay {
            out.append("猶予が日をまたぎます。\(state.times[3]) から \(state.killGrace) 分は 23:59 で切れるので、"
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
