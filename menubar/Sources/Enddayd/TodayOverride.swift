import Foundation

/// `/etc/enddayd.today` — 今日だけの調整。
///
/// 当日スキップと同じく日付印を押す。翌日は日付が合わないので自動的に失効する。
/// 「緩めたまま戻し忘れる」が起きない形にしておくのがこのツールの前提。
///
/// 判定の規則はデーモン側（`enddayd.sh` の `read_today`）と揃えてある。
/// ここが緩いと、GUI では効いているように見えてデーモンは無視する、という
/// 食い違いになる。
struct TodayOverride: Equatable {
    /// 強制終了を後ろへずらす分数。0 なら延長なし。
    var extendMinutes = 0
    /// 今日だけ差し替えるレベル。nil なら設定のまま。
    var level: EnforceLevel?

    var isActive: Bool { extendMinutes > 0 || level != nil }

    /// 人が読む1行。無ければ空。
    var summary: String {
        var parts: [String] = []
        if extendMinutes > 0 { parts.append("強制終了を \(extendMinutes)分 延長") }
        if let level { parts.append("レベルを \(level.rawValue) に変更") }
        return parts.joined(separator: " / ")
    }
}

enum TodayOverrideParser {

    /// 延長で選べる分数。`enddayd.sh` の `EXTEND_SLOTS` と同じ値でなければならない。
    ///
    /// 任意の分数にできないのは、launchd のトリガが plist に固定で書かれている
    /// ため。延ばした先に発火が無ければ、指定だけ残って落ちない。
    static let slots = [30, 60, 90, 120]

    static func parse(_ text: String, today: String) -> TodayOverride {
        let dict = ConfParser.keyValues(text)
        // 日付が違えば失効。これが自動で戻る仕組みそのもの。
        guard dict["DATE"] == today else { return TodayOverride() }

        var out = TodayOverride()
        if let raw = dict["EXTEND"], let n = Int(raw), slots.contains(n) {
            out.extendMinutes = n
        }
        if let raw = dict["LEVEL"], let level = EnforceLevel(rawValue: raw) {
            out.level = level
        }
        return out
    }

    /// その日に実際に受け付けてもらえる延長だけを返す。
    ///
    /// 日をまたぐ延長はデーモンが拒否するので、メニューにも出さない。
    /// 押しても必ず失敗する項目を並べるくらいなら、出さないほうがよい。
    static func allowedSlots(lastEnforce: String, killGrace: Int) -> [Int] {
        guard let last = ConfParser.minutes(of: lastEnforce) else { return [] }
        let endOfDay = 24 * 60 - 1
        return slots.filter { last + $0 + killGrace <= endOfDay }
    }
}
