import Foundation

/// 権限の要らない読み取りだけの問い合わせ。
/// 背景キューから呼ぶ前提なので、どこにも隔離していない。
enum DaemonProbe {

    /// launchd に実際に登録されているか。
    /// ファイルの有無では分からない（plist が残っていても `bootout` 済みなら動かない）。
    static func daemonLoaded(label: String) -> Bool {
        exitStatus("/bin/launchctl", ["print", "system/\(label)"]) == 0
    }

    /// 同梱の本体と導入済みの本体が違うか。
    ///
    /// 版番号ではなく中身で見る。番号は上げ忘れると「最新です」と嘘をつくが、
    /// 中身の比較なら古くならない。手で書き換えた場合も違いとして出る。
    /// どちらか読めなければ「違う」とは言わない（未導入と区別が付かないため）。
    static func installedDiffers(bundled: String?, installed: String) -> Bool {
        guard let bundled,
              let mine = FileManager.default.contents(atPath: bundled),
              let theirs = FileManager.default.contents(atPath: installed) else { return false }
        return mine != theirs
    }

    private static func exitStatus(_ path: String, _ arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
