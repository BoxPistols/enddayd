import Foundation

/// 管理者権限が要る操作の実行。
///
/// osascript の "do shell script ... with administrator privileges" を使い、
/// macOS 標準のパスワードダイアログを出す。アプリ自身は root を持たない。
enum Admin {

    struct CommandError: LocalizedError {
        let output: String
        var errorDescription: String? { output }
    }

    /// ユーザーがパスワード入力をキャンセルした
    struct Cancelled: Error {}

    /// シェルの単一引用符で安全に包む
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript の文字列リテラルとして安全に埋め込む
    private static func appleScriptQuote(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + out + "\""
    }

    /// 管理者権限でシェルコマンドを実行する。ブロックするので必ず背景キューから呼ぶ。
    @discardableResult
    static func run(_ command: String) throws -> String {
        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            // -128 はユーザーによるキャンセル。エラー表示にしない
            if err.contains("-128") { throw Cancelled() }
            throw CommandError(output: err.isEmpty ? out : err)
        }
        return out
    }
}
