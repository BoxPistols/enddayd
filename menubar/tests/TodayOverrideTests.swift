import Foundation

/// 今日だけの調整のテスト。
///
/// 見ているのは「デーモンが無視する指定を、GUI が効いているように見せないこと」。
/// 判定の規則は enddayd.sh の read_today と揃えてあるので、片方を変えたら
/// 両方直すこと。
enum TodayOverrideTests {

    static func run(_ t: inout Harness) {
        日付印(&t)
        延長(&t)
        レベル(&t)
        受け付けられる延長(&t)
        表示(&t)
    }

    private static func 日付印(_ t: inout Harness) {
        let text = "DATE=2026-08-16\nEXTEND=60\n"
        t.equal(TodayOverrideParser.parse(text, today: "2026-08-16").extendMinutes, 60,
                "today's stamp is honoured")

        // これが「翌日には勝手に戻る」仕組みそのもの
        t.equal(TodayOverrideParser.parse(text, today: "2026-08-17"), TodayOverride(),
                "yesterday's override expires on its own")

        // 日付が無いものは効かせない（いつのものか分からない指定を信じない）
        t.equal(TodayOverrideParser.parse("EXTEND=60", today: "2026-08-16"), TodayOverride(),
                "an override without a date is ignored")
    }

    private static func 延長(_ t: inout Harness) {
        // 受け皿のある分数だけ。無い分数を通すと、指定は残るのに落ちない
        for minutes in TodayOverrideParser.slots {
            let text = "DATE=2026-08-16\nEXTEND=\(minutes)\n"
            t.equal(TodayOverrideParser.parse(text, today: "2026-08-16").extendMinutes, minutes,
                    "an extension of \(minutes) is accepted")
        }
        for bad in ["45", "0", "-30", "999", "ten"] {
            let text = "DATE=2026-08-16\nEXTEND=\(bad)\n"
            t.equal(TodayOverrideParser.parse(text, today: "2026-08-16").extendMinutes, 0,
                    "an extension of \(bad) is refused")
        }
    }

    private static func レベル(_ t: inout Harness) {
        t.equal(TodayOverrideParser.parse("DATE=2026-08-16\nLEVEL=notify", today: "2026-08-16").level,
                .notify, "a level override is read")
        t.equal(TodayOverrideParser.parse("DATE=2026-08-16\nLEVEL=panic", today: "2026-08-16").level,
                nil, "an unknown level is refused")

        // 延長とレベルは同時に指定できる
        let both = TodayOverrideParser.parse("DATE=2026-08-16\nEXTEND=30\nLEVEL=soft",
                                             today: "2026-08-16")
        t.equal(both.extendMinutes, 30, "extension and level can be combined")
        t.equal(both.level, .soft, "the combined level is read")
    }

    /// 押しても必ず失敗する項目をメニューに並べない。
    /// 日をまたぐ延長はデーモンが拒否するので、出す側で先に落とす。
    private static func 受け付けられる延長(_ t: inout Harness) {
        t.equal(TodayOverrideParser.allowedSlots(lastEnforce: "18:50", killGrace: 10),
                [30, 60, 90, 120], "an ordinary schedule allows every slot")

        // 23:00 + 猶予10分 なら 30分 しか入らない（+60 は 24:10 になる）
        t.equal(TodayOverrideParser.allowedSlots(lastEnforce: "23:00", killGrace: 10),
                [30], "a late schedule allows only what fits before midnight")

        t.equal(TodayOverrideParser.allowedSlots(lastEnforce: "23:50", killGrace: 10),
                [], "a very late schedule allows nothing")

        // 猶予が長いほど入る余地が減る（22:00 + 60分延長 + 猶予60分 = 24:00 で溢れる）
        t.equal(TodayOverrideParser.allowedSlots(lastEnforce: "22:00", killGrace: 60),
                [30], "a longer grace leaves room for fewer slots")

        t.equal(TodayOverrideParser.allowedSlots(lastEnforce: "bogus", killGrace: 10),
                [], "an unreadable time allows nothing")
    }

    private static func 表示(_ t: inout Harness) {
        t.expect(!TodayOverride().isActive, "no override is not active")
        t.equal(TodayOverride().summary, "", "no override has no summary")

        var both = TodayOverride()
        both.extendMinutes = 60
        both.level = .notify
        t.expect(both.isActive, "an override with both fields is active")
        t.equal(both.summary, "強制終了を 60分 延長 / レベルを notify に変更",
                "the summary lists both changes")
    }
}
