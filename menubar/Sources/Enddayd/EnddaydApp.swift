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

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            // メニューバーに常駐する本体。テキストは状態に追従する
            Image(systemName: model.symbolName)
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
}
