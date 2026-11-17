import Foundation

/// GitHub Releasesの最新版と自分の版を比べる部分。通信と画面から切り離してある。
enum UpdateCheck {

    static let latestURL = URL(string: "https://api.github.com/repos/BoxPistols/enddayd/releases/latest")!

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        /// アプリのzip。添付が無いReleaseもあり得るので、そのときはページを開くだけにする
        let assetURL: URL?
    }

    /// "v0.9.0" / "0.9.0" → [0, 9, 0]。数字以外が混じる版（"0.9.0-beta"）は比べない
    static func components(_ version: String) -> [Int]? {
        var v = Substring(version)
        if v.hasPrefix("v") { v = v.dropFirst() }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// candidateがcurrentより新しいか。どちらかが読めなければ新しいとは言わない
    /// （「更新があります」と出し続けるより、出さないほうが害が小さい）
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = components(candidate), var b = components(current) else { return false }
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// releases/latestの応答を読む。下書きと先行版は対象にしない
    static func parse(_ data: Data) -> Release? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.draft != true, p.prerelease != true,
              let page = URL(string: p.html_url) else { return nil }
        var version = p.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        let asset = p.assets?
            .first { $0.name.hasPrefix("Enddayd") && $0.name.hasSuffix(".zip") }
            .flatMap { URL(string: $0.browser_download_url) }
        return Release(version: version, pageURL: page, assetURL: asset)
    }
}
