import Foundation

/// enddayd.shのsnapshot_terminalsが書く端末の記録（latest.tsv）の読み取り。
///
/// 1行目は`# 2026-08-17 18:30:00 warn`の見出し、2行目以降が1端末1行のタブ区切り
/// （端末・作業ディレクトリ・種類・コマンド・会話ID・会話の状態）。
/// 開き直す操作そのものはenddayd.shのrestoreに任せ、ここでは件数と時刻だけを読む。
enum TerminalSnapshot {

    struct Summary: Equatable {
        /// 見出しの日時（例: "2026-08-17 18:30:00"）
        let savedAt: String
        /// 段階名かtick
        let tag: String
        let terminals: Int
        let claudeSessions: Int
    }

    static func directory(home: String) -> String {
        home + "/Library/Application Support/enddayd/terminals"
    }

    /// 端末が1件も無い、または見出しが読めなければnil
    static func parse(_ text: String) -> Summary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let head = lines.first, head.hasPrefix("# ") else { return nil }
        let parts = head.dropFirst(2).split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let rows = lines.dropFirst().filter { !$0.hasPrefix("#") }
        guard !rows.isEmpty else { return nil }
        let claude = rows.filter {
            let cols = $0.split(separator: "\t", omittingEmptySubsequences: false)
            return cols.count > 2 && cols[2] == "claude"
        }.count
        return Summary(savedAt: "\(parts[0]) \(parts[1])", tag: String(parts[2]),
                       terminals: rows.count, claudeSessions: claude)
    }

    /// メニューに出す短い説明（例: "11/17 18:30・9件（Claude Code 4件）"）
    static func label(_ s: Summary) -> String {
        // "2026-08-17 18:30:00" → "8/17 18:30"
        let dt = s.savedAt.split(separator: " ")
        var when = s.savedAt
        if dt.count == 2 {
            let ymd = dt[0].split(separator: "-")
            let hm = dt[1].prefix(5)
            if ymd.count == 3, let m = Int(ymd[1]), let d = Int(ymd[2]) {
                when = "\(m)/\(d) \(hm)"
            }
        }
        let claude = s.claudeSessions > 0 ? "（Claude Code \(s.claudeSessions)件）" : ""
        return "\(when)・\(s.terminals)件\(claude)"
    }
}
