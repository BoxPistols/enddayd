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
    }
}
