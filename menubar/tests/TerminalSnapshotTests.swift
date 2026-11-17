import Foundation

/// 端末の記録の読み取り。列の並びはenddayd.shのcollect_terminalsと揃える。
enum TerminalSnapshotTests {

    static func run(_ t: inout Harness) {
        let text = """
        # 2026-08-17 18:30:00 warn
        ttys001\t/work/app\tshell\t\t\t
        ttys002\t/work/api\tclaude\tclaude\tsess-abc\tidle
        ttys003\t/work/web\tcommand\tnpm run dev\t\t
        """
        let s = TerminalSnapshot.parse(text)
        t.equal(s?.savedAt, "2026-08-17 18:30:00", "header time is read")
        t.equal(s?.tag, "warn", "header tag is read")
        t.equal(s?.terminals, 3, "every terminal row is counted")
        t.equal(s?.claudeSessions, 1, "claude rows are counted by the kind column")
        if let s {
            t.equal(TerminalSnapshot.label(s), "8/17 18:30・3件（Claude Code 1件）",
                    "label is short and names claude sessions")
        }

        // 見出しだけで端末が無い記録は「開き直すものが無い」
        t.equal(TerminalSnapshot.parse("# 2026-08-17 18:30:00 tick\n"), nil,
                "a record without terminals is nil")
        // 見出しの無いファイルは記録として扱わない
        t.equal(TerminalSnapshot.parse("ttys001\t/work\tshell\t\t\t"), nil,
                "a file without header is nil")
    }
}
