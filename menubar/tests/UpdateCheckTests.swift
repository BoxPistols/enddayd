import Foundation

/// 版の比較とReleaseの読み取り。ここを誤ると、古い版へ「更新」したり、
/// 最新なのに「更新があります」と出し続けたりする。
enum UpdateCheckTests {

    static func run(_ t: inout Harness) {
        t.equal(UpdateCheck.isNewer("0.9.0", than: "0.8.0"), true, "minor bump is newer")
        t.equal(UpdateCheck.isNewer("v0.10.0", than: "0.9.0"), true, "numbers are compared as integers")
        t.equal(UpdateCheck.isNewer("0.8.0", than: "0.8.0"), false, "same version is not newer")
        t.equal(UpdateCheck.isNewer("0.7.9", than: "0.8.0"), false, "older version is not newer")
        t.equal(UpdateCheck.isNewer("0.8", than: "0.8.0"), false, "missing parts count as zero")
        t.equal(UpdateCheck.isNewer("0.8.1", than: "0.8"), true, "longer version with a patch is newer")
        t.equal(UpdateCheck.isNewer("0.9.0-beta", than: "0.8.0"), false, "unreadable version is never newer")

        let json = """
        {"tag_name":"v0.9.0","html_url":"https://example.com/r/v0.9.0","draft":false,"prerelease":false,
         "assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
                   {"name":"Enddayd-0.9.0.zip","browser_download_url":"https://example.com/Enddayd-0.9.0.zip"}]}
        """
        let r = UpdateCheck.parse(Data(json.utf8))
        t.equal(r?.version, "0.9.0", "tag prefix v is dropped")
        t.equal(r?.assetURL?.absoluteString, "https://example.com/Enddayd-0.9.0.zip", "the app zip is picked among assets")

        let noAsset = #"{"tag_name":"v0.9.0","html_url":"https://example.com/r","assets":[]}"#
        t.equal(UpdateCheck.parse(Data(noAsset.utf8))?.assetURL, nil, "release without the zip has no asset")

        let pre = #"{"tag_name":"v1.0.0","html_url":"https://example.com/r","prerelease":true}"#
        t.equal(UpdateCheck.parse(Data(pre.utf8)), nil, "prerelease is ignored")
        t.equal(UpdateCheck.parse(Data("not json".utf8)), nil, "broken response is ignored")

        // 失敗を「最新」と取り違えない。取り違えると、既知の更新の知らせが消える
        let ok = Data(json.utf8)
        t.equal(UpdateCheck.outcome(status: 200, data: ok, current: "0.8.0"), .newer(r!), "newer release is reported")
        t.equal(UpdateCheck.outcome(status: 200, data: ok, current: "0.9.0"), .upToDate, "same version is up to date")
        t.equal(UpdateCheck.outcome(status: 404, data: nil, current: "0.8.0"), .upToDate, "no release yet is up to date")
        t.equal(UpdateCheck.outcome(status: 500, data: nil, current: "0.8.0"), .failed, "server error is a failure")
        t.equal(UpdateCheck.outcome(status: nil, data: nil, current: "0.8.0"), .failed, "network error is a failure")
        t.equal(UpdateCheck.outcome(status: 200, data: Data("x".utf8), current: "0.8.0"), .failed, "broken body is a failure")

        // 更新の方法ごとの扱い。自動を選んでも、強制終了の直前には置き換えない
        func act(_ mode: UpdateCheck.Mode, manual: Bool = false, asset: Bool = true,
                 prompted: Bool = false, near: Bool = false) -> UpdateCheck.Action {
            UpdateCheck.action(mode: mode, manual: manual, hasAsset: asset,
                               alreadyPrompted: prompted, nearEnforce: near)
        }
        t.equal(act(.confirm), .prompt, "confirm mode asks once")
        t.equal(act(.confirm, prompted: true), .none, "confirm mode does not ask twice for the same version")
        t.equal(act(.auto), .install, "auto mode installs without asking")
        t.equal(act(.auto, prompted: true), .install, "auto mode installs even after an earlier prompt")
        t.equal(act(.auto, near: true), .none, "auto mode waits while shutdown is near")
        t.equal(act(.auto, asset: false), .prompt, "auto mode without a zip falls back to asking")
        t.equal(act(.auto, manual: true), .prompt, "manual check always asks")
        t.equal(act(.confirm, manual: true, prompted: true), .prompt, "manual check asks again")

        let now = Date(timeIntervalSince1970: 1_000_000)
        t.equal(UpdateCheck.isNearEnforce(now: now, nextEnforce: now.addingTimeInterval(50 * 60), leadMinutes: 50),
                true, "notice time itself is near enforce")
        t.equal(UpdateCheck.isNearEnforce(now: now, nextEnforce: now.addingTimeInterval(51 * 60), leadMinutes: 50),
                false, "before notice is not near enforce")
        t.equal(UpdateCheck.isNearEnforce(now: now, nextEnforce: nil, leadMinutes: 50),
                false, "no schedule is never near enforce")
    }
}
