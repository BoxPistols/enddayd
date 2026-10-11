import AppKit

/// メニューバーの記号の色。メニューの「アイコンの色」から選ぶ。
///
/// モノクロだとほかの常駐アプリと見分けにくいので、既定は金色にしてある
/// （終業後の時間＝ゴールデンタイム）。色を付けるのは動いている状態
/// （電源記号・タイマー）だけで、停止中・未導入・異常は白黒のまま。
/// 「色が付いていれば効いている」と一目で読めるようにするため。
enum IconTint: String, CaseIterable, Identifiable {
    case gold
    case green
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gold:  return "金色（ゴールデンタイム）"
        case .green: return "緑（仕事を終えて一息）"
        case .mono:  return "モノクロ（ほかのアイコンと同じ）"
        }
    }

    /// nil はモノクロ（システムの文字色に追従する template 画像）。
    ///
    /// 明るいメニューバーと暗いメニューバーで同じ色だと、片方で沈む。
    /// 外観に合わせて濃さを変える（明るい側は背景との差が 3:1 を超える濃さ）。
    var color: NSColor? {
        switch self {
        case .gold:  return Self.adaptive(light: (0.69, 0.49, 0.06), dark: (0.95, 0.76, 0.31))
        case .green: return Self.adaptive(light: (0.12, 0.56, 0.31), dark: (0.36, 0.82, 0.54))
        case .mono:  return nil
        }
    }

    /// 外観で切り替わる色。値は数で受け取り、色は描く時点で作る
    /// （NSColor を閉包に持ち込むと Swift 6 の Sendable 検査に掛かる）。
    private static func adaptive(light: (Double, Double, Double),
                                 dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

enum MenuBarIcon {
    /// メニューバーに置く記号の画像。
    ///
    /// MenuBarExtra のラベルは template 画像を白黒に塗り直すので、
    /// `Image(systemName:)` に色を付けても効かない。色を出すときは
    /// 色を焼き込んだ画像を作り、template をやめる。
    static func image(symbol: String, color: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(textStyle: .body)
        if let color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = (color == nil)
        return image
    }
}
