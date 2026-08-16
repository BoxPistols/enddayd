import Foundation

/// 設定の解釈のテスト。
///
/// 見ているのは「デーモンが拒否する設定を、GUI が正常として表示しないこと」。
/// ここが緩いと、画面では 20:00 と出ているのにデーモンは走らない、という
/// 一番たちの悪い食い違いになる。判定の規則は enddayd.sh の validate_conf と
/// 揃えてあるので、片方を変えたら両方直すこと。
enum ConfParserTests {

    static let valid = """
    TIMES="18:00,18:30,18:45,18:50"
    WEEKDAYS="1,2,3,4,5"
    LEVEL="normal"
    LOGOUT_ATTEMPT="1"
    ALLOW_BYPASS="1"
    KILL_GRACE="10"
    """

    static func run(_ t: inout Harness) {
        妥当な設定(&t)
        必須項目の欠落(&t)
        時刻(&t)
        曜日(&t)
        レベルと数値(&t)
        真偽値(&t)
        書式(&t)
        猶予の警告(&t)
    }

    // 妥当な設定はそのまま読める
    private static func 妥当な設定(_ t: inout Harness) {
        let s = ConfParser.parse(valid)
        t.expect(!s.isBroken, "valid conf is accepted", s.problems.joined(separator: " / "))
        t.equal(s.times, ["18:00", "18:30", "18:45", "18:50"], "valid conf keeps the times")
        t.equal(s.weekdays, Set([1, 2, 3, 4, 5]), "valid conf keeps the weekdays")
        t.equal(s.level, .normal, "valid conf keeps the level")
        t.equal(s.killGrace, 10, "valid conf keeps the grace")
        t.expect(ConfParser.warnings(for: s).isEmpty, "valid conf raises no warning")
    }

    // 必須項目が無いとき既定値で補わない（補うと意図しない時刻で動く）
    private static func 必須項目の欠落(_ t: inout Harness) {
        for key in ["TIMES", "WEEKDAYS", "LEVEL"] {
            let text = valid
                .split(separator: "\n")
                .filter { !$0.hasPrefix("\(key)=") }
                .joined(separator: "\n")
            let s = ConfParser.parse(text)
            t.expect(s.isBroken, "missing \(key) is rejected")
            t.expect(s.problems.contains { $0.contains(key) }, "missing \(key) is named in the reason")
        }
        // KILL_GRACE は既定値を持つので、欠けていても壊れではない
        let s = ConfParser.parse(valid.replacingOccurrences(of: "KILL_GRACE=\"10\"", with: ""))
        t.expect(!s.isBroken, "a missing KILL_GRACE falls back to the default")
        t.equal(s.killGrace, 10, "the KILL_GRACE default is 10")
    }

    private static func 時刻(_ t: inout Harness) {
        let short = ConfParser.parse(valid.replacingOccurrences(
            of: "TIMES=\"18:00,18:30,18:45,18:50\"", with: "TIMES=\"18:00,18:30,18:45\""))
        t.expect(short.isBroken, "TIMES with three stages is rejected")

        let unsorted = ConfParser.parse(valid.replacingOccurrences(
            of: "TIMES=\"18:00,18:30,18:45,18:50\"", with: "TIMES=\"18:50,18:30,18:45,18:00\""))
        t.expect(unsorted.isBroken, "TIMES out of order is rejected")

        let malformed = ConfParser.parse(valid.replacingOccurrences(
            of: "TIMES=\"18:00,18:30,18:45,18:50\"", with: "TIMES=\"18:00,18:30,18:45,25:00\""))
        t.expect(malformed.isBroken, "TIMES with an impossible hour is rejected")

        // 1桁表記は弾く。デーモン側の valid_time が HH:MM しか通さないので、
        // ここで通すと GUI だけが受け入れて保存後に走らなくなる。
        let oneDigit = ConfParser.parse(valid.replacingOccurrences(
            of: "TIMES=\"18:00,18:30,18:45,18:50\"", with: "TIMES=\"9:00,18:30,18:45,18:50\""))
        t.expect(oneDigit.isBroken, "TIMES with a one digit hour is rejected")

        // 同時刻は「早い順」を満たさない
        let duplicate = ConfParser.parse(valid.replacingOccurrences(
            of: "TIMES=\"18:00,18:30,18:45,18:50\"", with: "TIMES=\"18:00,18:30,18:30,18:50\""))
        t.expect(duplicate.isBroken, "TIMES with a repeated time is rejected")

        // 壊れているときは既定値を保ち、その値を正しい設定として見せない
        t.equal(short.times, ["18:00", "18:30", "18:45", "18:50"],
                "a rejected TIMES does not overwrite the shown times")
    }

    private static func 曜日(_ t: inout Harness) {
        let empty = ConfParser.parse(valid.replacingOccurrences(
            of: "WEEKDAYS=\"1,2,3,4,5\"", with: "WEEKDAYS=\"\""))
        t.expect(empty.isBroken, "an empty WEEKDAYS is rejected")

        let outOfRange = ConfParser.parse(valid.replacingOccurrences(
            of: "WEEKDAYS=\"1,2,3,4,5\"", with: "WEEKDAYS=\"0,1\""))
        t.expect(outOfRange.isBroken, "WEEKDAYS outside 1-7 is rejected")

        // 数字でない値を黙って捨てない（捨てると曜日が減ったことに気づけない）
        let nonNumeric = ConfParser.parse(valid.replacingOccurrences(
            of: "WEEKDAYS=\"1,2,3,4,5\"", with: "WEEKDAYS=\"1,mon,3\""))
        t.expect(nonNumeric.isBroken, "a non numeric WEEKDAYS entry is rejected")
    }

    private static func レベルと数値(_ t: inout Harness) {
        let level = ConfParser.parse(valid.replacingOccurrences(
            of: "LEVEL=\"normal\"", with: "LEVEL=\"panic\""))
        t.expect(level.isBroken, "an unknown LEVEL is rejected")

        let grace = ConfParser.parse(valid.replacingOccurrences(
            of: "KILL_GRACE=\"10\"", with: "KILL_GRACE=\"ten\""))
        t.expect(grace.isBroken, "a non numeric KILL_GRACE is rejected")

        let negative = ConfParser.parse(valid.replacingOccurrences(
            of: "KILL_GRACE=\"10\"", with: "KILL_GRACE=\"-5\""))
        t.expect(negative.isBroken, "a negative KILL_GRACE is rejected")
    }

    private static func 真偽値(_ t: inout Harness) {
        // "yes" を真として黙って正規化しない。デーモンは 0/1 しか見ない
        let logout = ConfParser.parse(valid.replacingOccurrences(
            of: "LOGOUT_ATTEMPT=\"1\"", with: "LOGOUT_ATTEMPT=\"yes\""))
        t.expect(logout.isBroken, "a non 0/1 LOGOUT_ATTEMPT is rejected")

        let bypass = ConfParser.parse(valid.replacingOccurrences(
            of: "ALLOW_BYPASS=\"1\"", with: "ALLOW_BYPASS=\"2\""))
        t.expect(bypass.isBroken, "a non 0/1 ALLOW_BYPASS is rejected")

        let off = ConfParser.parse(valid.replacingOccurrences(
            of: "LOGOUT_ATTEMPT=\"1\"", with: "LOGOUT_ATTEMPT=\"0\""))
        t.expect(!off.isBroken && !off.logoutAttempt, "LOGOUT_ATTEMPT=0 is read as off")
    }

    private static func 書式(_ t: inout Harness) {
        // コメントと空行は読み飛ばす
        let commented = ConfParser.parse("# 説明\n\n" + valid)
        t.expect(!commented.isBroken, "comments and blank lines are ignored")

        // CRLF で保存されていても読める
        let crlf = valid.replacingOccurrences(of: "\n", with: "\r\n")
        t.expect(!ConfParser.parse(crlf).isBroken, "a CRLF file is read")

        // 値の前後の空白を許す
        let spaced = ConfParser.parse(valid.replacingOccurrences(
            of: "LEVEL=\"normal\"", with: "LEVEL = \"soft\" "))
        t.equal(spaced.level, .soft, "spaces around the value are tolerated")
    }

    private static func 猶予の警告(_ t: inout Harness) {
        // 23:55 + 10分 は 24:05 にならず 23:59 で切れる。拒否はしないが黙らない
        let late = ConfParser.parse("""
        TIMES="23:00,23:30,23:45,23:55"
        WEEKDAYS="1,2,3,4,5"
        LEVEL="normal"
        KILL_GRACE="10"
        """)
        t.expect(!late.isBroken, "a late schedule is still accepted")
        let warnings = ConfParser.warnings(for: late)
        t.equal(warnings.count, 1, "a grace crossing midnight raises one warning")
        t.expect(warnings.first?.contains("4 分") == true,
                 "the warning states the grace that actually applies",
                 warnings.joined())

        // ちょうど 23:59 に収まるなら警告しない
        let exact = ConfParser.parse("""
        TIMES="23:00,23:30,23:45,23:55"
        WEEKDAYS="1,2,3,4,5"
        LEVEL="normal"
        KILL_GRACE="4"
        """)
        t.expect(ConfParser.warnings(for: exact).isEmpty, "a grace ending at 23:59 is fine")

        // 壊れた設定に警告を重ねない（直すべきは壊れているほう）
        let broken = ConfParser.parse("WEEKDAYS=\"1\"\nLEVEL=\"normal\"")
        t.expect(ConfParser.warnings(for: broken).isEmpty, "a broken conf raises no warning")
    }
}
