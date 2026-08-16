import AppKit
import SwiftUI

/// 設定画面を画面に出さずに PNG へ落とす。
///
/// メニューバーのメニュー自体はネイティブUIなので撮れないが、設定画面は
/// ただのウィンドウなので、オフスクリーンのウィンドウに載せれば撮れる。
/// **ウィンドウは前面に出さない。** 出すと利用者の画面を奪う。
///
///   swift tools/Snapshot.swift <出力先ディレクトリ>
///
/// SwiftUI の onAppear はウィンドウに載らないと発火しない（ScheduleView は
/// そこで現在値を読む）。NSHostingView 単体では中身が空のまま撮れてしまうので、
/// 必ずウィンドウに入れてから撮る。
@main
struct Snapshot {

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let app = NSApplication.shared
        // .prohibited = Dock にも出ないし前面にも来ない
        app.setActivationPolicy(.prohibited)

        for (name, appearance) in [("light", NSAppearance(named: .aqua)),
                                   ("dark", NSAppearance(named: .darkAqua))] {
            guard let image = render(appearance: appearance) else {
                FileHandle.standardError.write(Data("描画に失敗しました (\(name))\n".utf8))
                exit(1)
            }
            let path = "\(outDir)/schedule-\(name).png"
            guard write(image, to: path) else {
                FileHandle.standardError.write(Data("書き出しに失敗しました: \(path)\n".utf8))
                exit(1)
            }
            print("\(path)  \(Int(image.size.width))x\(Int(image.size.height))")
        }
        exit(0)
    }

    @MainActor
    private static func render(appearance: NSAppearance?) -> NSBitmapImageRep? {
        let model = DaemonModel()
        // 地は SwiftUI 側で塗らせる。cacheDisplay はウィンドウの地を写さないので、
        // 塗らないと RGB が全部 0 でアルファだけの絵になり、色を判断できない。
        let root = ScheduleView()
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance

        // 幅は ScheduleView 側の .frame(width: 460) + 余白。高さは実測に任せる
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.appearance = appearance
        window.contentView = hosting
        // orderFront は呼ばない。呼ぶと画面に出る
        window.displayIfNeeded()

        // SwiftUI が落ち着くまで少し回す。onAppear もここで走る
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(size)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
