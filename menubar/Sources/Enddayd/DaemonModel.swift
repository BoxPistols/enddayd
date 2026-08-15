import Foundation
import Combine
import ServiceManagement

/// enddayd の強制終了レベル
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

/// デーモン側の状態。真実はすべてファイルにあり、このクラスは読むだけ。
/// 変更はすべて管理者権限のシェル経由で行い、終わったら読み直す。
@MainActor
final class DaemonModel: ObservableObject {

    // デーモンと共有しているパス（enddayd.sh と一致させる）
    static let binPath   = "/usr/local/bin/enddayd.sh"
    static let plistPath = "/Library/LaunchDaemons/local.enddayd.plist"
    static let confPath  = "/etc/enddayd.conf"
    static let dryPath   = "/etc/enddayd.dryrun"
    static let skipPath  = "/etc/enddayd.skip"
    static let logPath   = "/var/log/enddayd.log"

    // --- 読み取った状態 ---
    @Published var installed = false
    @Published var dryRun = true
    @Published var skipToday = false
    @Published var times: [String] = ["18:00", "18:30", "18:45", "18:50"]
    @Published var weekdays: Set<Int> = [1, 2, 3, 4, 5]   // 1=月 … 7=日
    @Published var level: EnforceLevel = .normal
    @Published var logoutAttempt = true
    @Published var allowBypass = true
    @Published var killGrace = 10
    @Published var confBroken = false
    @Published var logTail: [String] = []

    // --- 操作の進行状態 ---
    @Published var busy = false
    @Published var lastError: String?

    private var timer: AnyCancellable?

    init() {
        refresh()
        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    // ------------------------------------------------------------ 読み取り ---

    func refresh() {
        let fm = FileManager.default
        installed = fm.fileExists(atPath: Self.binPath) && fm.fileExists(atPath: Self.plistPath)
        dryRun = fm.fileExists(atPath: Self.dryPath)

        let today = Self.dateFormatter.string(from: Date())
        if let skip = try? String(contentsOfFile: Self.skipPath, encoding: .utf8) {
            skipToday = skip.trimmingCharacters(in: .whitespacesAndNewlines) == today
        } else {
            skipToday = false
        }

        readConf()
        readLogTail()
    }

    private func readConf() {
        guard let text = try? String(contentsOfFile: Self.confPath, encoding: .utf8) else {
            confBroken = false   // 未導入なら既定値のまま
            return
        }
        var dict: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            var val = String(s[s.index(after: eq)...])
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            dict[key] = val
        }

        var broken = false

        if let t = dict["TIMES"] {
            let parts = t.split(separator: ",").map(String.init)
            if parts.count == 4, parts.allSatisfy(Self.isValidTime) {
                times = parts
            } else { broken = true }
        }
        if let w = dict["WEEKDAYS"] {
            let parts = w.split(separator: ",").compactMap { Int($0) }
            if !parts.isEmpty, parts.allSatisfy({ (1...7).contains($0) }) {
                weekdays = Set(parts)
            } else { broken = true }
        }
        if let l = dict["LEVEL"] {
            if let lv = EnforceLevel(rawValue: l) { level = lv } else { broken = true }
        }
        if let g = dict["KILL_GRACE"] {
            if let n = Int(g), n >= 0 { killGrace = n } else { broken = true }
        }
        logoutAttempt = dict["LOGOUT_ATTEMPT"] != "0"
        allowBypass = dict["ALLOW_BYPASS"] != "0"
        confBroken = broken
    }

    private func readLogTail() {
        guard let text = try? String(contentsOfFile: Self.logPath, encoding: .utf8) else {
            logTail = []
            return
        }
        logTail = text.split(separator: "\n").suffix(3).map(String.init)
    }

    // ------------------------------------------------------ メニューバー表示 ---

    var symbolName: String {
        if !installed { return "sunset" }
        if dryRun { return "pause.circle" }
        return "sunset.fill"
    }

    var barText: String {
        guard installed else { return "" }
        if confBroken { return "設定エラー" }
        if dryRun { return "停止中" }
        if skipToday && isScheduledToday { return "今日は休み" }
        guard let next = nextEnforceDate() else { return "" }
        let minutes = Int(next.timeIntervalSinceNow / 60)
        if Calendar.current.isDateInToday(next) && minutes < 60 {
            return "あと\(max(minutes, 0))分"
        }
        return times[3]
    }

    var isScheduledToday: Bool {
        weekdays.contains(Self.isoWeekday(of: Date()))
    }

    /// 次に強制終了が来る日時（スキップ・ドライランは考慮しない素の予定）
    func nextEnforceDate() -> Date? {
        guard let (h, m) = Self.parseTime(times[3]) else { return nil }
        let cal = Calendar.current
        let now = Date()
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            guard weekdays.contains(Self.isoWeekday(of: day)) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = h
            comps.minute = m
            guard let candidate = cal.date(from: comps) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    // ------------------------------------------------------------ 操作 ---

    /// 管理者権限の操作を背景で実行し、終わったら状態を読み直す
    func adminAction(_ command: String, then completion: (@MainActor () -> Void)? = nil) {
        busy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try Admin.run(command)
                failure = nil
            } catch is Admin.Cancelled {
                failure = nil   // キャンセルは無言で戻す
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self, failure] in
                guard let self else { return }
                self.busy = false
                self.lastError = failure
                self.refresh()
                if failure == nil { completion?() }
            }
        }
    }

    func skipTodayOn() {
        adminAction("/bin/date +%F > \(Self.skipPath)")
    }

    func skipTodayOff() {
        adminAction("/bin/rm -f \(Self.skipPath)")
    }

    func pause() {
        adminAction("/usr/bin/touch \(Self.dryPath)")
    }

    /// 再開（本番へ）。呼ぶ側で確認を取ってから使う
    func resume() {
        adminAction("/bin/rm -f \(Self.dryPath)")
    }

    func install() {
        guard let script = Bundle.main.path(forResource: "enddayd", ofType: "sh") else {
            lastError = "アプリに enddayd.sh が同梱されていません"
            return
        }
        adminAction("/bin/bash \(Admin.shQuote(script)) install")
    }

    func uninstall() {
        let script = FileManager.default.fileExists(atPath: Self.binPath)
            ? Self.binPath
            : (Bundle.main.path(forResource: "enddayd", ofType: "sh") ?? Self.binPath)
        adminAction("/bin/bash \(Admin.shQuote(script)) uninstall")
    }

    func rehearsal() {
        adminAction("/bin/bash \(Admin.shQuote(Self.binPath)) rehearsal 5")
    }

    /// 設定を書いて reload する。値はこのアプリ側で検証済みであること。
    /// デーモン側の reload も同じ検証を持つので、二重で守られる。
    func saveConfig(times newTimes: [String], weekdays newDays: Set<Int>,
                    level newLevel: EnforceLevel, logout: Bool, bypass: Bool, grace: Int) {
        let sorted = newDays.sorted().map(String.init).joined(separator: ",")
        let lines = [
            "# enddayd 設定ファイル。手で編集したら sudo \(Self.binPath) reload を実行してください。",
            "# reload は内容を検証し、通らなければ何も差し替えません。",
            "TIMES=\"\(newTimes.joined(separator: ","))\"",
            "WEEKDAYS=\"\(sorted)\"",
            "LEVEL=\"\(newLevel.rawValue)\"",
            "LOGOUT_ATTEMPT=\"\(logout ? 1 : 0)\"",
            "ALLOW_BYPASS=\"\(bypass ? 1 : 0)\"",
            "KILL_GRACE=\"\(grace)\"",
        ]
        // 値の文字種は数字・コロン・カンマ・英小文字に限られるので printf で安全に書ける
        let content = lines.joined(separator: "\\n")
        let cmd = "/usr/bin/printf '%b\\n' \(Admin.shQuote(content)) > \(Self.confPath) && /bin/bash \(Admin.shQuote(Self.binPath)) reload"
        adminAction(cmd)
    }

    // -------------------------------------------------- ログイン時に起動 ---

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "ログイン時起動の設定に失敗: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // ------------------------------------------------------------ 補助 ---

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func isValidTime(_ s: String) -> Bool {
        parseTime(s) != nil
    }

    static func parseTime(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// 1=月 … 7=日（enddayd.sh の date +%u と同じ）
    static func isoWeekday(of date: Date) -> Int {
        let w = Calendar.current.component(.weekday, from: date)  // 1=日 … 7=土
        return w == 1 ? 7 : w - 1
    }

    static func weekdayName(_ n: Int) -> String {
        ["月", "火", "水", "木", "金", "土", "日"][(n - 1) % 7]
    }
}
