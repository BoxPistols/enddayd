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
        行の長さ(&t)
        日付の省略(&t)
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

    /// メニューの幅は一番長い項目で決まる。起動中アプリの一覧のような行を
    /// 素で出すとメニューが画面いっぱいに広がるので、表示用に丸める。
    private static func 行の長さ(_ t: inout Harness) {
        let long = "2026-08-16 18:30:00 [DRY] running apps: "
            + (1...20).map { "App\($0)" }.joined(separator: ", ")
        let line = LogReader.facts(long).tail.first ?? ""
        t.equal(line.count, LogReader.tailLineLimit, "a long line is cut to the limit")
        t.expect(line.hasSuffix("…"), "a cut line says it was cut", line)

        // 収まる行には触らない（末尾に記号が付くと切れたように読める）
        let short = "2026-08-16 18:00:00 notice shown"
        t.equal(LogReader.facts(short).tail, [short], "a short line is left alone")

        // 上限ちょうどの行も切らない
        let exact = String(repeating: "x", count: LogReader.tailLineLimit)
        t.equal(LogReader.facts(exact).tail, [exact], "a line exactly at the limit is left alone")

        // 日本語（1文字が複数バイト）でも文字数で数える
        let japanese = String(repeating: "あ", count: LogReader.tailLineLimit + 10)
        t.equal(LogReader.facts(japanese).tail.first?.count, LogReader.tailLineLimit,
                "a multibyte line is counted in characters")
    }

    /// メニューの幅を決めているのはログ行。今日の行の日付は情報を持たないので落とす。
    private static func 日付の省略(_ t: inout Harness) {
        let line = "2026-08-16 05:16:41 [DRY] stage=enforce level=soft user=ai"

        t.equal(LogReader.facts(line, today: "2026-08-16").tail,
                ["05:16:41 [DRY] stage=enforce level=soft user=ai"],
                "today's date is dropped from the shown line")

        // 別の日の行は日付を残す（いつのものか分からなくなる）
        t.equal(LogReader.facts(line, today: "2026-08-17").tail, [line],
                "another day keeps its date")

        // today を渡さなければ何もしない（ログそのものは変えない）
        t.equal(LogReader.facts(line).tail, [line], "without today nothing is stripped")

        // 日付を落としてから長さを測る（先に測ると無駄に切れる）
        let long = "2026-08-16 05:16:41 [DRY] running apps: "
            + (1...20).map { "App\($0)" }.joined(separator: ", ")
        let shown = LogReader.facts(long, today: "2026-08-16").tail.first ?? ""
        t.expect(shown.hasPrefix("05:16:41"), "the date is dropped before truncating", shown)
        t.equal(shown.count, LogReader.tailLineLimit, "the result still respects the limit")

        // 到達記録は表示用の丸めを受けない（日時がそのまま要る）
        let reached = "2026-08-16 18:50:01 enforce reached level=normal"
        t.equal(LogReader.facts(reached, today: "2026-08-16").lastEnforce,
                "2026-08-16 18:50:01 level=normal",
                "the enforce record keeps its full date")
    }
}
