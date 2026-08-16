import Foundation

/// enddayd の強制終了レベル。`enddayd.sh` の `LEVEL` と同じ値。
///
/// このファイルと ConfParser / LogReader は Foundation しか使わない。
/// 画面や権限から切り離してあるので、テスト（`menubar/tests/`）から
/// そのまま読み込める。
enum EnforceLevel: String, CaseIterable, Identifiable {
    case notify, soft, normal, hard
    var id: String { rawValue }

    var label: String {
        switch self {
        case .notify: return "notify — 通知のみ。電源は落とさない"
        case .soft:   return "soft — アプリに終了を依頼。未保存があれば止まる"
        case .normal: return "normal — root から shutdown。アプリの拒否権なし"
        case .hard:   return "hard — セッションを畳んでから shutdown"
        }
    }
}
