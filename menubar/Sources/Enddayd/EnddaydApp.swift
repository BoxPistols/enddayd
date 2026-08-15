import SwiftUI

@main
struct EnddaydApp: App {
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
