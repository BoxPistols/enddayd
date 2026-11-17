import Foundation

/// テストの入口。
///
/// 件数（PLANNED）は手で宣言する。呼び忘れて 0 件でも「成功」と出る状態を
/// 避けるため、Harness が実行数と突き合わせて合わなければ落とす。
/// テストを足したらここも直すこと。
@main
struct TestMain {

    /// ConfParserTests 52件 + LogReaderTests 23件 + TodayOverrideTests 28件 + TerminalSnapshotTests 7件 + UpdateCheckTests 18件
    static let planned = 134

    static func main() {
        var harness = Harness()
        ConfParserTests.run(&harness)
        LogReaderTests.run(&harness)
        TodayOverrideTests.run(&harness)
        TerminalSnapshotTests.run(&harness)
        UpdateCheckTests.run(&harness)
        harness.finish(planned: planned)
    }
}
