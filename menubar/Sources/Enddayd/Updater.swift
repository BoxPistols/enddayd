import Foundation
import AppKit
import UserNotifications

/// アプリ自身の更新。GitHub Releasesを1日1回見て、新しい版があれば
/// メニューバーの赤い点とメニューの項目で知らせる。そのうえで、利用者が選んだ
/// 「更新の方法」に従い、版ごとに1回ポップアップで聞くか、自動で置き換える。
///
/// 置き換えるのはアプリだけ。常駐している本体（/usr/local/bin/enddayd.sh）は
/// 管理者権限が要るので、更新後にDaemonModelが違いを検出して
/// 「本体を更新する…」を出す既存の経路に任せる。
@MainActor
final class Updater: ObservableObject {

    @Published private(set) var available: UpdateCheck.Release?
    @Published private(set) var busy = false
    /// 確認の通信中。続けて押されても要求を重ねない
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "updateLastCheck"
    private static let promptedKey = "updatePromptedVersion"
    static let modeKey = "updateMode"
    /// 自動で置き換えた版。開き直した後に「更新しました」を1回だけ知らせる
    private static let installedKey = "updateAutoInstalledVersion"

    /// 強制終了の予告から強制終了までの間か。アプリの入口でDaemonModelにつなぐ
    var isNearEnforce: () -> Bool = { false }

    var mode: UpdateCheck.Mode {
        UpdateCheck.Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .confirm
    }

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        announceAutoInstallIfAny()
        // 起動直後はログイン時の他のアプリと重なるので少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkIfDue()
        }
        // スリープを挟むと1日おきのTimerは当てにならないので、1時間ごとに「期限が来たか」を見る
        // 強制終了の前で見送った自動更新も、ここで改めて試す
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfDue()
                self?.applyKnownUpdate()
            }
        }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Date().timeIntervalSince1970 - last >= Self.checkInterval { check(manual: false) }
    }

    /// manualはメニューの「更新を確認」から。結果を必ず画面に出す
    func check(manual: Bool) {
        guard !checking, !busy else { return }
        checking = true
        var request = URLRequest(url: UpdateCheck.latestURL)
        // GitHubはUser-Agentの無い要求を断る。利用者を識別する情報は載せない
        request.setValue("Enddayd", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            let outcome: UpdateCheck.Outcome
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                outcome = UpdateCheck.outcome(status: (response as? HTTPURLResponse)?.statusCode,
                                              data: data, current: Self.currentVersion)
            } catch {
                outcome = .failed
            }
            checking = false
            switch outcome {
            case .newer(let release):
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                available = release
                handle(release, manual: manual)
            case .upToDate:
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                available = nil
                if manual { inform("最新です（\(Self.currentVersion)）", "") }
            case .failed:
                // 確認時刻は進めない（1時間後にまた確かめる）。既に知っている更新の知らせは残す
                if manual { inform("更新を確認できませんでした", "通信できないか、GitHubから想定外の応答がありました。時間をおいてもう一度試してください。") }
            }
        }
    }

    /// メニューで方法を変えたとき。自動に切り替えた時点で知っている更新があれば、そのまま進める
    func setMode(_ newMode: UpdateCheck.Mode) {
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        applyKnownUpdate()
    }

    /// 既に知っている更新を、いまの方法で扱い直す（通信はしない）
    private func applyKnownUpdate() {
        guard let r = available, !busy else { return }
        handle(r, manual: false)
    }

    private func handle(_ r: UpdateCheck.Release, manual: Bool) {
        let action = UpdateCheck.action(
            mode: mode, manual: manual, hasAsset: r.assetURL != nil,
            alreadyPrompted: UserDefaults.standard.string(forKey: Self.promptedKey) == r.version,
            nearEnforce: isNearEnforce())
        switch action {
        // 設定の画面を開いている間は開き直さない。書きかけの設定が消える
        case .install where Self.settingsWindowIsOpen: break
        case .install: update(auto: true)
        case .prompt:  prompt(r)
        case .none:    break
        }
    }

    private static var settingsWindowIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.contains("schedule") == true }
    }

    /// 同じ版では1回だけ出す（記録はhandleが読む）。毎日出ると閉じるだけの操作になり、知らせとして効かなくなる
    private func prompt(_ r: UpdateCheck.Release) {
        UserDefaults.standard.set(r.version, forKey: Self.promptedKey)

        let alert = NSAlert()
        alert.messageText = "Enddayd \(r.version)が出ています"
        alert.informativeText = "いまは\(Self.currentVersion)です。メニューの「\(r.version)に更新する」からいつでも更新できます。"
        alert.addButton(withTitle: r.assetURL == nil ? "Releaseを開く" : "更新する")
        alert.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { update() }
    }

    /// autoは自動更新から。失敗してもダイアログは出さず、メニューの項目と赤い点を残して次の機会に任せる
    func update(auto: Bool = false) {
        // 確認が重なってポップアップから再び呼ばれても、置き換えを重ねない
        guard !busy, let r = available else { return }
        guard let asset = r.assetURL else {
            NSWorkspace.shared.open(r.pageURL)
            return
        }
        // 自分のIDが分からなければ、取ってきた中身が同じアプリかを確かめられないので更新しない
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            inform("更新できませんでした", "このアプリのバンドルIDを読めませんでした。")
            return
        }
        busy = true
        lastError = nil
        let target = Bundle.main.bundleURL
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try await Self.install(from: asset, version: r.version, bundleID: bundleID, into: target)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self, failure] in
                guard let self else { return }
                self.busy = false
                if let failure {
                    self.lastError = failure
                    if !auto { self.inform("更新できませんでした", failure) }
                } else {
                    if auto { UserDefaults.standard.set(r.version, forKey: Self.installedKey) }
                    Self.relaunch(target)
                }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// 取ってきたzipを展開し、中身が同じアプリの指定の版であることを確かめてから置き換える。
    /// 確かめずに置くと、Releaseの添付を取り違えたときに別物で上書きしてしまう。
    nonisolated private static func install(from asset: URL, version: String,
                                            bundleID: String, into target: URL) async throws {
        let fm = FileManager.default
        let (zip, _) = try await URLSession.shared.download(from: asset)
        let work = fm.temporaryDirectory.appendingPathComponent("enddayd-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
            throw UpdateError("zipを展開できませんでした")
        }
        let app = work.appendingPathComponent("Enddayd.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("zipの中にEnddayd.appがありません")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("zipの中身がEnddaydではありません")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("zipの中身の版が\(version)ではありません")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else {
            throw UpdateError("zipの中のアプリの署名を確かめられませんでした")
        }
        do {
            _ = try fm.replaceItemAt(target, withItemAt: app)
        } catch {
            throw UpdateError("\(target.path)を置き換えられませんでした（\(error.localizedDescription)）")
        }
    }

    /// 自分が終わってから開き直す。先に開くと二重起動の防止（AppDelegate）で新しいほうが閉じる
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 自動で更新して開き直した直後に、macOSの通知で1回だけ知らせる。
    /// 黙って版が変わると、動きが変わったときに原因へたどり着けない
    private func announceAutoInstallIfAny() {
        let defaults = UserDefaults.standard
        guard let version = defaults.string(forKey: Self.installedKey) else { return }
        defaults.removeObject(forKey: Self.installedKey)
        // 置き換えに失敗して古い版のまま開いたときは知らせない
        guard version == Self.currentVersion else { return }
        // 送り先は閉包の中で取り直す（外から持ち込むとSwift 6のSendable検査に掛かる）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Enddaydを\(version)に更新しました"
            content.body = "更新の方法はメニューの「更新の方法」で変えられます。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "enddayd-updated-\(version)",
                                             content: content, trigger: nil))
        }
    }

    private func inform(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
