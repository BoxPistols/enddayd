import Foundation

/// ログから読み取る事実のテスト。
///
/// ここが緩いと「ドライランの記録を本番の実績として見せる」ことになり、
/// 効いていないのに効いているように見える。enddayd.sh の status と
/// 同じ規則（`[DRY]` の付いた行は本番ではない）で判定する。
enum LogReaderTests {

    static func run(_ t: inout Harness) {
        本番の到達(&t)
        ドライランの除外(&t)
        自動化の許可(&t)
        末尾(&t)
    }

    private static func 本番の到達(_ t: inout Harness) {
        let log = """
        2026-08-16 18:50:01 stage=enforce level=normal user=ai
        2026-08-16 18:50:01 enforce reached level=normal
        2026-08-16 18:50:01 level=normal: shutdown -h now
        """
        let facts = LogReader.facts(log)
        t.equal(facts.lastEnforce, "2026-08-16 18:50:01 level=normal",
                "a production enforce is read and reformatted")

        // 複数回あれば最後のもの
        let twice = log + "\n2026-08-17 18:50:02 enforce reached level=hard"
        t.equal(LogReader.facts(twice).lastEnforce, "2026-08-17 18:50:02 level=hard",
                "the newest production enforce wins")

        // 一度も無ければ nil。空欄と「まだ無い」を呼び分けるのは表示側
        t.equal(LogReader.facts("2026-08-16 18:00:00 notice shown").lastEnforce, nil,
                "no enforce line means nil")
    }

    private static func ドライランの除外(_ t: inout Harness) {
        let dry = """
        2026-08-16 18:50:01 [DRY] stage=enforce level=normal user=ai
        2026-08-16 18:50:01 [DRY] would execute level=normal
        """
        t.equal(LogReader.facts(dry).lastEnforce, nil,
                "a dry run is not counted as a production enforce")

        // 本番のあとにドライランを流しても、本番の実績は消えない
        let mixed = """
        2026-08-16 18:50:01 enforce reached level=normal
        2026-08-16 19:10:00 [DRY] would execute level=normal
        """
        t.equal(LogReader.facts(mixed).lastEnforce, "2026-08-16 18:50:01 level=normal",
                "a later dry run does not erase the production record")
    }

    private static func 自動化の許可(_ t: inout Harness) {
        t.equal(LogReader.facts("2026-08-16 18:30:00 [DRY] automation ok: 到達できました").automation,
                .ok, "automation ok is read")
        t.equal(LogReader.facts("2026-08-16 18:30:00 [DRY] automation denied: 操作できません").automation,
                .denied, "automation denied is read")
        t.equal(LogReader.facts("2026-08-16 18:00:00 notice shown").automation,
                .unknown, "no automation line means unknown")

        // 許可を与えたあとに古い denied を出し続けない
        let fixed = """
        2026-08-16 18:30:00 [DRY] automation denied: 操作できません
        2026-08-17 18:30:00 [DRY] automation ok: 到達できました
        """
        t.equal(LogReader.facts(fixed).automation, .ok, "the newest automation result wins")
    }

    private static func 末尾(_ t: inout Harness) {
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")
        t.equal(LogReader.facts(log, tailCount: 3).tail, ["line 8", "line 9", "line 10"],
                "the tail is the last three lines")

        // 末尾の空行でログが空に見えないこと
        t.equal(LogReader.facts("line 1\n\n\n", tailCount: 3).tail, ["line 1"],
                "trailing blank lines are dropped")
        t.equal(LogReader.facts("").tail, [], "an empty log yields no lines")
    }
}
