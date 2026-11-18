import SwiftUI
import AppKit

/// 二重起動を防ぐ。ビルドした場所と /Applications の両方を開くと
/// メニューバーにアイコンが2つ並び、どちらを操作しているか分からなくなる。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let first = others.first {
            first.activate()
            NSApp.terminate(nil)
        }
    }
}

@main
struct EnddaydApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DaemonModel()
    @StateObject private var updater = Updater()
    @AppStorage("iconTint") private var tint: IconTint = .gold

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
                .environmentObject(updater)
        } label: {
            // メニューバーに常駐する本体。テキストは状態に追従する
            // 色を付けるのは動いている状態だけ（IconTint の説明を参照）
            // 更新があることはメニューを開かなくても見えるように、記号の右上に赤い点を付ける
            if let image = MenuBarIcon.image(symbol: model.symbolName,
                                             color: model.symbolIsActive ? tint.color : nil,
                                             badge: updater.available != nil) {
                Image(nsImage: image)
                    .onAppear { connectUpdater() }
            } else {
                Image(systemName: model.symbolName)
                    .onAppear { connectUpdater() }
            }
            if !model.barText.isEmpty {
                Text(model.barText)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("enddayd 設定", id: "schedule") {
            ScheduleView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// 自動更新が強制終了の直前に走らないよう、本体の時刻を更新側から読めるようにする
    private func connectUpdater() {
        updater.isNearEnforce = { [weak model] in model?.isNearEnforce() ?? false }
    }
}
