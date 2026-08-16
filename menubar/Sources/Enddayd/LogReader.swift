import Foundation

/// 警告段階のログアウト試行に要る「自動化」の許可の状態。
/// アプリからは許可の有無を直接引けないので、デーモンが残したログから読む。
enum AutomationStatus: Equatable {
    case unknown   // まだ警告段階を通っていない
    case ok
    case denied
}

/// `/var/log/enddayd.log` から読み取れること。表示のためだけの型。
struct LogFacts: Equatable {
    var tail: [String] = []
    /// 本番（ドライランでない）で最後に強制終了まで到達した記録。
    /// 表示用に整形済み（例: `2026-08-16 18:50:00 level=normal`）。
    var lastEnforce: String?
    var automation: AutomationStatus = .unknown
}

enum LogReader {

    /// ドライランの行には `enddayd.sh` の `log()` が `[DRY]` を付ける。
    /// 本番の記録だけを拾うのに使う。
    static let dryMarker = "[DRY]"
    static let enforceMarker = "enforce reached "

    static func facts(_ text: String, tailCount: Int = 3) -> LogFacts {
        var facts = LogFacts()
        // 区切りは isNewline で見る（CRLF は Swift では 1 文字なので、
        // "\n" や "\r" との比較では取りこぼす）
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        facts.tail = Array(lines.suffix(tailCount))

        if let line = lines.last(where: { !$0.contains(dryMarker) && $0.contains(enforceMarker) }) {
            facts.lastEnforce = line.replacingOccurrences(of: enforceMarker, with: "")
        }

        // 最後に分かった状態を採る。許可を与えたあとに古い denied を
        // 出し続けると、直したのに直っていないように見える。
        if let line = lines.last(where: { $0.contains("automation ok") || $0.contains("automation denied") }) {
            facts.automation = line.contains("automation denied") ? .denied : .ok
        }

        return facts
    }
}
