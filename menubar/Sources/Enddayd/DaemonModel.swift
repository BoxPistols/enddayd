import Foundation
import Combine
import ServiceManagement

/// デーモン側の状態。真実はすべてファイルにあり、このクラスは読むだけ。
/// 変更はすべて管理者権限のシェル経由で行い、終わったら読み直す。
@MainActor
final class DaemonModel: ObservableObject {

    // デーモンと共有しているパス（enddayd.sh と一致させる）。
    // 背景キューからも読むので主アクターに縛らない（縛ると Swift 6 で
    // コンパイルが通らなくなる）。
    nonisolated static let label     = "local.enddayd"
    nonisolated static let binPath   = "/usr/local/bin/enddayd.sh"
    nonisolated static let plistPath = "/Library/LaunchDaemons/local.enddayd.plist"
    nonisolated static let confPath  = "/etc/enddayd.conf"
    nonisolated static let dryPath   = "/etc/enddayd.dryrun"
    nonisolated static let skipPath  = "/etc/enddayd.skip"
    nonisolated static let logPath   = "/var/log/enddayd.log"

    // --- 読み取った状態 ---
    @Published var installed = false
    @Published var dryRun = true
    @Published var skipToday = false
    @Published private(set) var conf = ConfState()
    @Published private(set) var confWarnings: [String] = []
    @Published private(set) var logFacts = LogFacts()

    /// launchd に実際に登録されているか。ファイルの有無とは別で、
    /// plist が残ったまま外れている状態を見分けるために要る。
    @Published private(set) var daemonLoaded = false

    /// 同梱の本体と導入済みの本体が違う。更新の導線を出す合図。
    @Published private(set) var updateAvailable = false

    // 設定は ConfState 1 つにまとめ、参照側はここを通す
    var times: [String] { conf.times }
    var weekdays: Set<Int> { conf.weekdays }
    var level: EnforceLevel { conf.level }
    var logoutAttempt: Bool { conf.logoutAttempt }
    var allowBypass: Bool { conf.allowBypass }
    var killGrace: Int { conf.killGrace }
    var confBroken: Bool { conf.isBroken }
    var confProblems: [String] { conf.problems }

    var logTail: [String] { logFacts.tail }
    var lastEnforce: String? { logFacts.lastEnforce }
    var automation: AutomationStatus { logFacts.automation }

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
        readLog()
        refreshProbes()
    }

    private func readConf() {
        guard let text = try? String(contentsOfFile: Self.confPath, encoding: .utf8) else {
            conf = ConfState()          // 未導入なら既定値のまま
            confWarnings = []
            return
        }
        conf = ConfParser.parse(text)
        confWarnings = ConfParser.warnings(for: conf)
    }

    private func readLog() {
        guard let text = try? String(contentsOfFile: Self.logPath, encoding: .utf8) else {
            logFacts = LogFacts()
            return
        }
        logFacts = LogReader.facts(text)
    }

    /// 外部プロセスとファイル比較は背景でやる。30秒ごとに主スレッドを
    /// 止めると、メニューを開いた瞬間に固まって見える。
    private func refreshProbes() {
        let bundled = Self.bundledScriptPath
        Task.detached(priority: .utility) {
            let loaded = DaemonProbe.daemonLoaded(label: DaemonModel.label)
            let differs = DaemonProbe.installedDiffers(bundled: bundled,
                                                       installed: DaemonModel.binPath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.daemonLoaded = loaded
                self.updateAvailable = differs
            }
        }
    }

    nonisolated static var bundledScriptPath: String? {
        Bundle.main.path(forResource: "enddayd", ofType: "sh")
    }

    // ------------------------------------------------------ メニューバー表示 ---

    var symbolName: String {
        if !installed { return "sunset" }
        if confBroken || !daemonLoaded { return "exclamationmark.triangle" }
        if dryRun { return "pause.circle" }
        return "sunset.fill"
    }

    var barText: String {
        guard installed else { return "" }
        if confBroken { return "設定エラー" }
        // 本体と plist はあるのに launchd から外れている。放っておくと
        // 「入れたのに何も起きない」になるので、停止中と区別して出す。
        if !daemonLoaded { return "未常駐" }
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

    /// 導入と更新は同じ経路。`install` は導入済みならモードを保つので、
    /// 本番で動いているものを更新しても勝手に停止しない（enddayd.sh 側の約束）。
    func install() {
        guard let script = Self.bundledScriptPath else {
            lastError = "アプリに enddayd.sh が同梱されていません"
            return
        }
        adminAction("/bin/bash \(Admin.shQuote(script)) install")
    }

    func uninstall() {
        let script = FileManager.default.fileExists(atPath: Self.binPath)
            ? Self.binPath
            : (Self.bundledScriptPath ?? Self.binPath)
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

    /// 時刻の妥当性は ConfParser に一本化する。ここに別の規則を書くと、
    /// 表示は通るのに保存すると弾かれる（またはその逆）という食い違いが出る。
    static func parseTime(_ s: String) -> (Int, Int)? {
        guard let total = ConfParser.minutes(of: s) else { return nil }
        return (total / 60, total % 60)
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
